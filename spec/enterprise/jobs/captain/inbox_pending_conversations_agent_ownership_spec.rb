require 'rails_helper'

RSpec.describe Captain::InboxPendingConversationsResolutionJob, type: :job do
  let(:account) { create(:account, auto_resolve_after: 60) }
  let(:inbox) { create(:inbox, account: account) }
  let(:entry) do
    create(:captain_assistant, account: account, config: {
             'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Entry closure',
             'handoff_message_enabled' => true, 'handoff_message_mode' => 'static', 'handoff_message' => 'Entry transfer'
           })
  end
  let(:specialist) do
    create(:captain_assistant, account: account, config: {
             'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Specialist closure',
             'handoff_message_enabled' => true, 'handoff_message_mode' => 'static', 'handoff_message' => 'Specialist transfer'
           })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, last_activity_at: 2.hours.ago, status: :pending) }
  let(:evaluation) { { complete: true, reason: 'Answered' } }
  let(:completion_service) { instance_double(Captain::ConversationCompletionService, perform: evaluation) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [specialist.id])
    specialist.update!(handoff_agent_ids: [entry.id])
    inbox.reload
    allow(inbox.account).to receive(:feature_enabled?).and_call_original
    allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
    allow(Captain::ConversationCompletionService).to receive(:new).and_return(completion_service)
    route_to(specialist)
  end

  def route_to(assistant)
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: assistant.id)
  end

  def expect_no_auto_action
    described_class.perform_now(inbox)

    expect(conversation.reload).to be_pending
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.status_transitions).to be_empty
  end

  it 'uses the current specialist for resolution text, private notes and status attribution' do
    described_class.perform_now(inbox)

    expect(conversation.reload).to be_resolved
    expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist closure', sender: specialist)
    expect(conversation.messages.where(private: true).last).to have_attributes(content: 'Auto-resolved: Answered', sender: specialist)
    expect(conversation.status_transitions.last).to have_attributes(actor: specialist, source: 'system')
  end

  it 'uses the specialist configuration for a time-based resolution' do
    inbox.account.update!(captain_auto_resolve_mode: 'legacy')

    described_class.perform_now(inbox)

    expect(Captain::ConversationCompletionService).not_to have_received(:new)
    expect(conversation.reload).to be_resolved
    expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist closure', sender: specialist)
    expect(conversation.status_transitions.last.actor).to eq(specialist)
  end

  it 'honors the specialist completion opt-out even when the entry allows completion' do
    specialist.update!(config: specialist.config.merge('auto_completion_enabled' => false))

    expect_no_auto_action
    expect(Captain::ConversationCompletionService).not_to have_received(:new)
  end

  it 'allows specialist completion when the entry has opted out' do
    entry.update!(config: entry.config.merge('auto_completion_enabled' => false))

    described_class.perform_now(inbox)

    expect(conversation.reload).to be_resolved
    expect(conversation.status_transitions.last.actor).to eq(specialist)
  end

  it 'does not fall back to the entry after a specialist is disabled' do
    specialist.update!(active: false)

    expect_no_auto_action
    expect(Captain::ConversationCompletionService).not_to have_received(:new)
  end

  it 'does not auto-complete a specialist conversation after the entry is disabled' do
    entry.update_columns(active: false)

    expect_no_auto_action
    expect(Captain::ConversationCompletionService).not_to have_received(:new)
  end

  it 'does not fall back to the entry after access to the specialist is removed' do
    Captain::AgentHandoff.where(source_assistant: entry, target_assistant: specialist).delete_all

    expect_no_auto_action
    expect(Captain::ConversationCompletionService).not_to have_received(:new)
  end

  it 'fences an evaluation when the conversation transfers to the entry' do
    allow(completion_service).to receive(:perform) do
      route_to(entry)
      evaluation
    end

    expect_no_auto_action
  end

  it 'fences an evaluation when a specialist leaves and becomes current again' do
    allow(completion_service).to receive(:perform) do
      route_to(entry)
      route_to(specialist)
      evaluation
    end

    expect_no_auto_action
  end

  it 'rechecks completion settings after evaluation' do
    allow(completion_service).to receive(:perform) do
      specialist.update!(config: specialist.config.merge('auto_completion_enabled' => false))
      evaluation
    end

    expect_no_auto_action
  end

  it 'rechecks specialist activation after evaluation' do
    allow(completion_service).to receive(:perform) do
      specialist.update!(active: false)
      evaluation
    end

    expect_no_auto_action
  end

  it 'fences a completed evaluation after shared Captain control changes' do
    allow(completion_service).to receive(:perform) do
      conversation.captain_control_owner.increment!(:captain_control_generation)
      evaluation
    end

    expect_no_auto_action
  end

  context 'when evaluation requires a human handoff' do
    let(:evaluation) { { complete: false, reason: 'Needs clarification' } }

    it 'uses the specialist handoff message and identity' do
      described_class.perform_now(inbox)

      expect(conversation.reload).to be_open
      expect(conversation.messages.outgoing.where(private: false).last).to have_attributes(content: 'Specialist transfer', sender: specialist)
      expect(conversation.messages.where(private: true).last).to have_attributes(content: 'Auto-handoff: Needs clarification', sender: specialist)
      expect(conversation.status_transitions.last.actor).to eq(specialist)
    end

    it 'fences a stale specialist handoff when routing changes during evaluation' do
      allow(completion_service).to receive(:perform) do
        route_to(entry)
        evaluation
      end

      expect_no_auto_action
    end
  end
end
