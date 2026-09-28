require 'rails_helper'

RSpec.describe Captain::Conversation::ControlService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:thread) { create(:communication_thread, account: account, contact: contact) }
  let(:first_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }

  before do
    create(:communication_thread_conversation, communication_thread: thread, conversation: first_conversation)
    create(:communication_thread_conversation, communication_thread: thread, conversation: second_conversation)
    [first_conversation, second_conversation].each do |conversation|
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
    end
  end

  it 'invalidates already queued work across a thread without changing a second pending conversation' do
    stale_generation = second_conversation.current_captain_control_generation

    first_conversation.activate_captain_human_control!(source: 'agent_reply')

    expect(thread.reload.captain_control_generation).to eq(stale_generation + 1)
    expect(thread.captain_control_state).to eq('human')
    expect(second_conversation.reload).to be_pending
    expect(second_conversation.bot_handoff!(fence: { control_generation: stale_generation })).to eq(:stale)
  end

  it 'bumps the generation when an open conversation returns to pending' do
    first_conversation.bot_handoff!
    human_generation = thread.reload.captain_control_generation
    expect(thread.captain_control_state).to eq('human')
    agent = create(:user, account: account)

    Conversations::StatusTransitionService.new(
      conversation: first_conversation, params: { status: 'pending' }, actor: agent, source: 'api'
    ).perform

    expect(first_conversation.reload).to be_pending
    expect(thread.reload).to have_attributes(
      captain_control_generation: human_generation + 1,
      captain_control_state: 'ai',
      captain_handoff_applied_at: nil
    )
  end

  it 'keeps a direct human activation idempotent when its conversation is already open' do
    first_conversation.update!(status: :open)

    expect(first_conversation.activate_captain_human_control!(source: 'agent_reply')).to be false
    expect(thread.reload.captain_control_generation).to eq(0)
  end

  it 'locks the conversation before the thread owner during handoff' do
    lock_order = []
    allow(second_conversation).to receive(:captain_control_owner).and_return(thread)
    allow(second_conversation).to receive(:with_lock).and_wrap_original do |method, *args, **kwargs, &block|
      lock_order << :conversation
      method.call(*args, **kwargs, &block)
    end
    allow(thread).to receive(:with_lock).and_wrap_original do |method, *args, **kwargs, &block|
      lock_order << :owner
      method.call(*args, **kwargs, &block)
    end

    second_conversation.bot_handoff!(fence: { control_generation: thread.captain_control_generation })

    expect(lock_order).to eq([:conversation, :owner, :conversation])
  end

  it 'locks the conversation before the thread owner during explicit release' do
    agent = create(:user, account: account)
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    expect(second_conversation).to receive(:with_lock).ordered.and_call_original
    expect(second_conversation).to receive(:with_captain_control_lock).ordered.and_call_original

    Conversations::StatusTransitionService.new(
      conversation: second_conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect(second_conversation.reload).to be_pending
  end

  it 'locks the conversation before the thread owner while capturing an employee takeover' do
    lock_order = []
    allow(second_conversation).to receive(:captain_control_owner).and_return(thread)
    allow(second_conversation).to receive(:with_lock).and_wrap_original do |method, *args, **kwargs, &block|
      lock_order << :conversation
      method.call(*args, **kwargs, &block)
    end
    allow(thread).to receive(:with_lock).and_wrap_original do |method, *args, **kwargs, &block|
      lock_order << :owner
      method.call(*args, **kwargs, &block)
    end

    second_conversation.activate_captain_human_control!(source: 'agent_reply')
    expect(lock_order).to eq([:conversation, :owner])
  end

  it 'reloads stale status after locking the conversation row' do
    agent = create(:user, account: account)
    stale_conversation = second_conversation
    # Simulate an external committed update without refreshing the loaded instance.
    # rubocop:disable Rails/SkipsModelValidations
    Conversation.where(id: stale_conversation.id).update_all(status: Conversation.statuses[:resolved])
    # rubocop:enable Rails/SkipsModelValidations

    Conversations::StatusTransitionService.new(
      conversation: stale_conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect(stale_conversation.reload.status).to eq('pending')
    expect(stale_conversation.status_transitions.order(:id).last).to have_attributes(
      from_status: 'resolved', to_status: 'pending'
    )
  end

  context 'when an employee replies from a non-Captain channel' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let!(:incoming) { create(:message, conversation: second_conversation, message_type: :incoming) }
    let(:key) { format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: second_conversation.id) }

    before do
      first_conversation.update!(status: :open)
      create(:captain_inbox, inbox: second_conversation.inbox, captain_assistant: assistant)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after { Redis::Alfred.delete(key) }

    it 'rejects a late handoff even when its generation is current' do
      create(:message, conversation: first_conversation, message_type: :outgoing, sender: create(:user, account: account))

      expect(described_class.human_response_after?(second_conversation, incoming.id)).to be true
      fence = { control_generation: thread.reload.captain_control_generation, last_message_id: incoming.id }
      expect(second_conversation.bot_handoff!(fence: fence)).to eq(:stale)
      expect(first_conversation.reload).to be_open
      expect(second_conversation.reload).to be_pending
    end

    {
      'private note' => { private: true },
      'scheduled touch' => { content_attributes: { touch_id: 123, touch_source: 'touch' } },
      'template bootstrap' => { additional_attributes: { template_params: { name: 'synthetic_template' } } }
    }.each do |name, attributes|
      it "ignores a non-Captain #{name} for the pending sibling" do
        create(:message, conversation: first_conversation, message_type: :outgoing, sender: create(:user, account: account), **attributes)

        expect(described_class.human_response_after?(second_conversation, incoming.id)).to be false
        expect(thread.reload.captain_control_generation).to eq(0)
        expect(Redis::Alfred.get(key)).to be_nil
        expect(first_conversation.reload).to be_open
        expect(second_conversation.reload).to be_pending
      end
    end

    it 'ignores an automated non-Captain source response for the pending sibling' do
      create(:message, conversation: first_conversation, message_type: :outgoing, sender: create(:agent_bot, account: account))

      expect(described_class.human_response_after?(second_conversation, incoming.id)).to be false
      expect(thread.reload.captain_control_generation).to eq(0)
      expect(Redis::Alfred.get(key)).to be_nil
    end

    it 'ignores public employee replies outside the target account and thread' do
      [create(:conversation, account: account, status: :open), create(:conversation, status: :open)].each do |source|
        create(:message, conversation: source, message_type: :outgoing, sender: create(:user, account: source.account))
      end

      expect(described_class.human_response_after?(second_conversation, incoming.id)).to be false
      expect(thread.reload.captain_control_generation).to eq(0)
      expect(Redis::Alfred.get(key)).to be_nil
    end
  end

  context 'without an eligible pending Captain target' do
    %i[open pending resolved snoozed].each do |status|
      it "keeps a non-Captain #{status} source unchanged after a public reply" do
        first_conversation.update!(status: status)
        generation = thread.reload.captain_control_generation
        expect(Captain::Conversation::ResponseCancellationService).not_to receive(:new)

        create(:message, conversation: first_conversation, message_type: :outgoing, sender: create(:user, account: account))

        expect(thread.reload.captain_control_generation).to eq(generation)
        expect(first_conversation.reload.status).to eq(status.to_s)
        expect(second_conversation.reload).to be_pending
      end
    end

    %i[open resolved snoozed].each do |status|
      it "keeps a Captain #{status} source unchanged when no pending target has an assistant" do
        assistant = create(:captain_assistant, account: account)
        create(:captain_inbox, inbox: first_conversation.inbox, captain_assistant: assistant)
        first_conversation.update!(status: status)
        generation = thread.reload.captain_control_generation
        expect(Captain::Conversation::ResponseCancellationService).not_to receive(:new)

        create(:message, conversation: first_conversation, message_type: :outgoing, sender: create(:user, account: account))

        expect(thread.reload.captain_control_generation).to eq(generation)
        expect(first_conversation.reload.status).to eq(status.to_s)
        expect(second_conversation.reload).to be_pending
      end
    end
  end
end
