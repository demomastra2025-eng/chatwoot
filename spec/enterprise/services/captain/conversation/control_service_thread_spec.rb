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
end
