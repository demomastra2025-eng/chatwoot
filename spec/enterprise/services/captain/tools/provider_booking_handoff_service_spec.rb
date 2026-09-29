require 'rails_helper'

RSpec.describe Captain::Tools::ProviderBookingHandoffService do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:conversation) { create(:conversation, account: account, status: :pending) }
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming) }
  let(:fence) do
    {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
  end

  before { create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant) }

  it 'opens a system-authorized human handoff with one private staff note' do
    service = described_class.new(assistant: assistant, conversation: conversation, fence: fence)

    expect(service.perform).to eq(:applied)
    expect(service.perform).to eq(:stale)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.current_captain_control_state).to eq('human')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not hand off when a newer Captain control generation exists' do
    captured_fence = fence
    conversation.activate_captain_human_control!(source: 'test')
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)

    result = described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform

    expect(result).to eq(:stale)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not leave a late note after a newer Captain run has handed off to another human' do
    captured_fence = fence
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)
    conversation.update!(status: :open)

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not accept a forged cross-account assistant' do
    other_assistant = create(:captain_assistant, account: create(:account))

    expect(described_class.new(assistant: other_assistant, conversation: conversation, fence: fence).perform).to eq(:invalid_context)
    expect(conversation.reload.status).to eq('pending')
  end

  it 'does not take over a conversation whose inbox belongs to a different Captain assistant' do
    replacement = create(:captain_assistant, account: account, usage_mode: 'external_agent')
    conversation.inbox.captain_inbox.update!(captain_assistant: replacement)

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: fence).perform).to eq(:invalid_context)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'records a staff note when a human is already assigned to a pending conversation' do
    conversation.update!(assignee: create(:user, account: account))

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: fence).perform).to eq(:already_applied)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'records a staff note after an agent public reply took the conversation over' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, user: agent, inbox: conversation.inbox)
    captured_fence = fence
    create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                     sender: agent, private: false, content: 'agent reply')
    conversation.reload

    expect(conversation.status).to eq('open')
    expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  context 'when a handoff opened the conversation before the booking failed late' do
    def perform_late_failure(captured_fence)
      conversation.reload
      expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
      described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform
    end

    def expect_one_late_staff_note(captured_fence)
      expect(perform_late_failure(captured_fence)).to eq(:stale)
      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.outgoing.pluck(:private)).to eq([true])
    end

    it 'records a staff note after the handoff tool of the same Captain run' do
      captured_fence = fence
      expect(conversation.bot_handoff!(source: 'captain', actor: assistant, fence: captured_fence)).to eq(:applied)

      expect_one_late_staff_note(captured_fence)
    end

    it 'records a staff note after a newer Captain run of the same pending episode handed off' do
      captured_fence = fence
      newer_incoming = create(:message, conversation: conversation, message_type: :incoming)
      newer_fence = captured_fence.merge(last_message_id: newer_incoming.id)
      expect(conversation.bot_handoff!(source: 'captain', actor: assistant, fence: newer_fence)).to eq(:applied)

      expect_one_late_staff_note(captured_fence)
    end

    it 'records a staff note after an agent handed the conversation off through the API' do
      captured_fence = fence
      expect(conversation.bot_handoff!(actor: create(:user, account: account, role: :agent))).to eq(:applied)

      expect_one_late_staff_note(captured_fence)
    end
  end

  # Only a return of this conversation to pending or an explicit staff release
  # hands control back to Captain; other resolves keep the staff takeover.
  context 'when the conversation is resolved after a staff public reply took it over' do
    let(:agent) { create(:user, account: account, role: :agent) }

    before do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after { Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)) }

    def take_over!
      captured_fence = fence
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                       sender: agent, private: false, content: 'agent reply')
      expect(conversation.reload).to be_open
      captured_fence
    end

    def resolve!(source:, actor:)
      Conversations::StatusTransitionService.new(
        conversation: conversation.reload, params: { status: 'resolved' }, actor: actor, source: source
      ).perform
      expect(conversation.reload).to be_resolved
    end

    def actor_for(kind)
      { agent: agent, contact: conversation.contact }.fetch(kind) { create(:automation_rule, account: account) }
    end

    def perform_late_failure(captured_fence, steps:)
      expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + steps)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      conversation.messages.outgoing.where(private: true).count
    end

    it 'records a staff note after the auto-resolve job resolved the conversation' do
      captured_fence = take_over!
      conversation.toggle_status
      expect(conversation.reload).to be_resolved

      expect(perform_late_failure(captured_fence, steps: 1)).to eq(1)
    end

    {
      'a staff macro' => %w[macro agent],
      'an automation rule' => %w[automation automation_rule],
      'the contact' => %w[contact contact],
      'a reminder after delivery' => %w[system agent]
    }.each do |label, (source, actor)|
      it "records a staff note after #{label} resolved the conversation" do
        captured_fence = take_over!
        resolve!(source: source, actor: actor_for(actor.to_sym))

        expect(perform_late_failure(captured_fence, steps: 1)).to eq(1)
      end
    end

    %w[api manual bulk_action communication_thread copilot].each do |source|
      it "does not leave a late note after staff explicitly resolved the conversation through #{source}" do
        captured_fence = take_over!
        resolve!(source: source, actor: agent)

        expect(perform_late_failure(captured_fence, steps: 2)).to eq(0)
      end
    end
  end

  context 'when the conversation shares a communication thread with a non-Captain channel' do
    let(:sibling) { create(:conversation, account: account, contact: conversation.contact, status: :open) }
    let(:thread) { create(:communication_thread, account: account, contact: conversation.contact) }
    let(:agent) { create(:user, account: account, role: :agent) }

    before do
      [conversation, sibling].each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after { Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)) }

    def staff_reply_in_sibling!(count)
      count.times do |index|
        create(:message, conversation: sibling, account: account, inbox: sibling.inbox, message_type: :outgoing,
                         sender: agent, private: false, content: "agent reply #{index}")
      end
    end

    def return_sibling_to!(status)
      Conversations::StatusTransitionService.new(conversation: sibling, params: { status: status }, actor: agent, source: 'api').perform
    end

    it 'records a staff note after a staff public reply in the sibling took the thread over' do
      captured_fence = fence
      create(:message, conversation: sibling, account: account, inbox: sibling.inbox, message_type: :outgoing,
                       sender: agent, private: false, content: 'agent reply')

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
      expect(conversation.reload).to be_pending
      expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing.pluck(:private)).to eq([true])
    end

    it 'does not leave a late note when only the sibling returned to Captain' do
      captured_fence = fence
      Conversations::StatusTransitionService.new(conversation: sibling, params: { status: 'pending' }, actor: agent, source: 'api').perform

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing).to be_empty
    end

    # Each staff public reply moves the thread generation again while this
    # Captain conversation stays pending.
    it 'records one staff note after several staff public replies in the sibling' do
      captured_fence = fence
      staff_reply_in_sibling!(3)

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 3)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing.pluck(:private)).to eq([true])
    end

    # Transition ids are global: a sibling transition before the fence can have
    # an id above this conversation's status epoch.
    it 'ignores a sibling return to Captain from before the fence' do
      %w[pending open].each { |status| return_sibling_to!(status) }
      captured_fence = fence
      expect(sibling.status_transitions.maximum(:id)).to be > captured_fence[:status_transition_id]
      staff_reply_in_sibling!(2)

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 2)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing.pluck(:private)).to eq([true])
    end

    it 'does not leave a late note when the sibling returned to Captain after staff replies' do
      captured_fence = fence
      staff_reply_in_sibling!(2)
      return_sibling_to!('pending')

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 3)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing).to be_empty
    end

    it 'does not leave a late note when staff resolved the sibling after replying' do
      captured_fence = fence
      staff_reply_in_sibling!(1)
      return_sibling_to!('resolved')

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 2)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.messages.outgoing).to be_empty
    end

    def resolve_sibling!(source:, actor:)
      Conversations::StatusTransitionService.new(
        conversation: sibling.reload, params: { status: 'resolved' }, actor: actor, source: source
      ).perform
      expect(sibling.reload).to be_resolved
    end

    def late_staff_notes(captured_fence, steps:)
      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + steps)
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      conversation.messages.outgoing.where(private: true).count
    end

    it 'records a staff note after the auto-resolve job resolved the idle sibling after a takeover here' do
      captured_fence = fence
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                       sender: agent, private: false, content: 'agent reply')
      expect(conversation.reload).to be_open
      sibling.reload.toggle_status
      expect(sibling.reload).to be_resolved

      expect(late_staff_notes(captured_fence, steps: 1)).to eq(1)
    end

    it 'records a staff note after the auto-resolve job resolved the sibling that took the thread over' do
      captured_fence = fence
      staff_reply_in_sibling!(1)
      sibling.reload.toggle_status
      expect(sibling.reload).to be_resolved

      expect(late_staff_notes(captured_fence, steps: 1)).to eq(1)
      expect(conversation.reload).to be_pending
    end

    it 'records a staff note after a staff macro resolved the sibling that took the thread over' do
      captured_fence = fence
      staff_reply_in_sibling!(1)
      resolve_sibling!(source: 'macro', actor: agent)

      expect(late_staff_notes(captured_fence, steps: 1)).to eq(1)
      expect(conversation.reload).to be_pending
    end

    it 'does not leave a late note when staff resolved the sibling from the communication thread after replying' do
      captured_fence = fence
      staff_reply_in_sibling!(1)
      resolve_sibling!(source: 'communication_thread', actor: agent)

      expect(late_staff_notes(captured_fence, steps: 2)).to eq(0)
    end

    # Without a status epoch a release cannot be ruled out.
    it 'accepts only a single takeover step for a fence without a status epoch' do
      captured_fence = fence.except(:status_transition_id)
      staff_reply_in_sibling!(2)

      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.messages.outgoing).to be_empty
    end
  end

  context 'when another Captain channel of the same communication thread is pending' do
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:thread) { create(:communication_thread, account: account, contact: conversation.contact) }
    let(:other_inbox) { create(:inbox, account: account) }
    let(:captain_sibling) { create(:conversation, account: account, contact: conversation.contact, inbox: other_inbox, status: :pending) }

    before do
      create(:captain_inbox, inbox: other_inbox, captain_assistant: create(:captain_assistant, account: account, usage_mode: 'external_agent'))
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      [conversation, captain_sibling].each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after do
      [conversation, captain_sibling].each do |candidate|
        Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: candidate.id))
      end
    end

    it 'records one staff note after two staff public replies in this conversation' do
      captured_fence = fence
      2.times do |index|
        create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                         sender: agent, private: false, content: "agent reply #{index}")
      end

      expect(thread.reload.captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 2)
      expect(captain_sibling.reload).to be_pending
      expect(described_class.new(assistant: assistant, conversation: conversation.reload, fence: captured_fence).perform).to eq(:stale)
      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    end
  end

  it 'does not leave a late note after staff replies around a return to Captain' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, user: agent, inbox: conversation.inbox)
    captured_fence = fence
    reply = lambda do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                       sender: agent, private: false, content: 'agent reply')
    end
    reply.call
    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, actor: agent, source: 'api').perform
    reply.call
    conversation.reload

    expect(conversation.status).to eq('open')
    expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 3)
    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing.where(private: true)).to be_empty
  end

  it 'does not leave a late note after the conversation returned to Captain and was opened again' do
    captured_fence = fence
    agent = create(:user, account: account, role: :agent)
    %w[open pending open].each do |status|
      Conversations::StatusTransitionService.new(conversation: conversation, params: { status: status }, actor: agent, source: 'api').perform
    end
    conversation.reload

    expect(conversation.status).to eq('open')
    expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not let the legacy captain_control_state column decide a late note' do
    captured_fence = fence
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)
    conversation.update!(status: :open)
    conversation.captain_control_owner.update_column(:captain_control_state, 'human') # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'fails closed without a response fence' do
    expect(described_class.new(assistant: assistant, conversation: conversation).perform).to eq(:missing_fence)
    expect(conversation.reload.status).to eq('pending')
  end
end
