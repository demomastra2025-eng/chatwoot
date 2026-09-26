require 'rails_helper'

RSpec.describe Captain::InboxPendingConversationsResolutionJob, type: :job do
  let!(:inbox) { create(:inbox) }
  let!(:resolvable_pending_conversation) { create(:conversation, inbox: inbox, last_activity_at: 2.hours.ago, status: :pending) }
  let!(:recent_pending_conversation) { create(:conversation, inbox: inbox, last_activity_at: 1.minute.ago, status: :pending) }
  let!(:open_conversation) { create(:conversation, inbox: inbox, last_activity_at: 1.hour.ago, status: :open) }
  let!(:captain_assistant) { create(:captain_assistant, account: inbox.account) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: captain_assistant)
    stub_const('Limits::BULK_ACTIONS_LIMIT', 3)
    inbox.account.update!(auto_resolve_after: 60)
    inbox.reload
  end

  it 'queues the job' do
    expect { described_class.perform_later(inbox) }
      .to have_enqueued_job.on_queue('low')
  end

  context 'when captain_tasks is disabled' do
    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(false)
    end

    it 'resolves pending conversations inactive for over 1 hour' do
      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('resolved')
    end

    it 'does not resolve recent pending conversations' do
      described_class.perform_now(inbox)

      expect(recent_pending_conversation.reload.status).to eq('pending')
    end

    it 'does not affect open conversations' do
      described_class.perform_now(inbox)

      expect(open_conversation.reload.status).to eq('open')
    end

    it 'does not call ConversationCompletionService' do
      allow(Captain::ConversationCompletionService).to receive(:new)

      described_class.perform_now(inbox)

      expect(Captain::ConversationCompletionService).not_to have_received(:new)
    end
  end

  context 'when captain_tasks is enabled' do
    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
    end

    it 'only evaluates eligible pending conversations (inactive > 1 hour)' do
      allow(Captain::ConversationCompletionService).to receive(:new).and_call_original

      # Mock the service to return complete for all conversations
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return({ complete: true, reason: 'Test' })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)

      described_class.perform_now(inbox)

      # Only resolvable conversation should be evaluated (not recent or open)
      expect(Captain::ConversationCompletionService).to have_received(:new).with(
        account: inbox.account,
        conversation_display_id: resolvable_pending_conversation.display_id
      )
      expect(recent_pending_conversation.reload.status).to eq('pending')
      expect(open_conversation.reload.status).to eq('open')
    end

    it 'skips auto-action if conversation receives new activity after evaluation' do
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform) do
        resolvable_pending_conversation.update!(last_activity_at: Time.current)
        { complete: true, reason: 'Customer question was answered' }
      end
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)

      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('pending')
      expect(resolvable_pending_conversation.messages.outgoing).to be_empty
    end

    it 'falls back to legacy time-based resolve when legacy auto-resolve is forced' do
      inbox.account.update!(captain_auto_resolve_mode: 'legacy')
      allow(Captain::ConversationCompletionService).to receive(:new)

      described_class.perform_now(inbox)

      expect(Captain::ConversationCompletionService).not_to have_received(:new)
      expect(resolvable_pending_conversation.reload.status).to eq('resolved')
    end
  end

  context 'when LLM evaluation returns complete' do
    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return({ complete: true, reason: 'Customer question was answered' })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
    end

    it 'resolves the conversation' do
      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('resolved')
    end

    it 'creates a private note with the reason' do
      described_class.perform_now(inbox)

      private_note = resolvable_pending_conversation.messages.where(private: true).last
      expect(private_note.content).to eq('Auto-resolved: Customer question was answered')
    end

    it 'creates resolution message with configured static content' do
      custom_message = 'This is a custom resolution message.'
      captain_assistant.update!(config: {
                                  'resolution_message_enabled' => true,
                                  'resolution_message_mode' => 'static',
                                  'resolution_message' => custom_message
                                })
      inbox.reload

      described_class.perform_now(inbox)

      public_message = resolvable_pending_conversation.messages.where(private: false).outgoing.last
      expect(public_message.content).to eq(custom_message)
    end

    it 'does not create resolution message when disabled' do
      captain_assistant.update!(config: {
                                  'resolution_message_enabled' => false,
                                  'resolution_message_mode' => 'static',
                                  'resolution_message' => ''
                                })
      inbox.reload

      expect do
        described_class.perform_now(inbox)
      end.not_to(change { resolvable_pending_conversation.messages.where(private: false).outgoing.count })
    end

    it 'does not fall back to default public text when static resolution message is blank' do
      captain_assistant.update!(config: {
                                  'resolution_message_enabled' => true,
                                  'resolution_message_mode' => 'static',
                                  'resolution_message' => ''
                                })
      inbox.reload

      expect do
        described_class.perform_now(inbox)
      end.not_to(change { resolvable_pending_conversation.messages.where(private: false).outgoing.count })
    end

    it 'uses generated resolution text when AI resolution message mode is enabled' do
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return(
        { complete: true, reason: 'Customer question was answered', message: 'I’m closing this because your question has been answered.' }
      )
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
      captain_assistant.update!(config: {
                                  'resolution_message_enabled' => true,
                                  'resolution_message_mode' => 'ai',
                                  'resolution_message' => ''
                                })
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

      described_class.perform_now(inbox)

      public_message = resolvable_pending_conversation.messages.where(private: false).outgoing.last
      expect(public_message.content).to eq('I’m closing this because your question has been answered.')
    end

    it 'adds the correct activity message after resolution' do
      described_class.perform_now(inbox)

      expected_content = I18n.with_locale(inbox.account.locale) do
        I18n.t(
          'conversations.activity.captain.resolved_with_reason',
          user_name: captain_assistant.name,
          reason: 'no outstanding questions'
        )
      end
      expect(Conversations::ActivityMessageJob)
        .to have_been_enqueued.with(
          resolvable_pending_conversation,
          {
            account_id: resolvable_pending_conversation.account_id,
            inbox_id: resolvable_pending_conversation.inbox_id,
            message_type: :activity,
            content: expected_content
          }
        )
    end

    it 'creates a captain inference resolved reporting event' do
      perform_enqueued_jobs do
        described_class.perform_now(inbox)
      end

      inference_event = ReportingEvent.find_by(
        conversation_id: resolvable_pending_conversation.id,
        name: 'conversation_captain_inference_resolved'
      )
      expect(inference_event).to be_present
    end
  end

  context 'when LLM evaluation returns incomplete' do
    let(:handoff_reason) { 'Assistant asked for order number but customer did not respond' }

    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return({ complete: false, reason: handoff_reason })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
    end

    it 'leaves the conversation pending when evaluation is incomplete even with the handoff tool enabled' do
      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('pending')
      expect(resolvable_pending_conversation.messages.outgoing).to be_empty
    end

    it 'does not force a handoff or send a handoff message when the tool is disabled' do
      captain_assistant.update!(config: captain_assistant.config.deep_merge(
        'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
      ))
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      initial_message_count = resolvable_pending_conversation.messages.count

      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('pending')
      expect(resolvable_pending_conversation.messages.count).to eq(initial_message_count)
      expect(resolvable_pending_conversation.captain_handoff_applied_at).to be_nil
    end

    it 'does not claim an automatic handoff in a private note' do
      described_class.perform_now(inbox)

      private_note = resolvable_pending_conversation.messages.where(private: true).last
      expect(private_note).to be_nil
    end

    it 'does not use configured static handoff text without a tool call' do
      handoff_message = 'Connecting you to a human agent...'
      captain_assistant.update!(config: {
                                  'handoff_message_enabled' => true,
                                  'handoff_message_mode' => 'static',
                                  'handoff_message' => handoff_message
                                })
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

      described_class.perform_now(inbox)

      public_message = resolvable_pending_conversation.messages.where(private: false).outgoing.last
      expect(public_message).to be_nil
    end

    it 'does not use generated handoff text without a tool call' do
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return(
        { complete: false, reason: handoff_reason, message: 'A specialist will continue with your request.' }
      )
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
      captain_assistant.update!(config: {
                                  'handoff_message_enabled' => true,
                                  'handoff_message_mode' => 'ai',
                                  'handoff_message' => ''
                                })
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

      described_class.perform_now(inbox)

      public_message = resolvable_pending_conversation.messages.where(private: false).outgoing.last
      expect(public_message).to be_nil
    end

    it 'preserves waiting_since without scheduling a handoff' do
      handoff_message = 'Connecting you to a human agent...'
      original_waiting_since = 3.hours.ago

      captain_assistant.update!(config: {
                                  'handoff_message_enabled' => true,
                                  'handoff_message_mode' => 'static',
                                  'handoff_message' => handoff_message
                                })
      resolvable_pending_conversation.update!(waiting_since: original_waiting_since)
      allow(MessageTemplates::Template::OutOfOffice).to receive(:perform_if_applicable)
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.waiting_since).to be_within(1.second).of(original_waiting_since)
    end

    it 'does not create handoff message if not configured' do
      captain_assistant.update!(config: {})
      inbox.reload
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

      expect do
        described_class.perform_now(inbox)
      end.not_to(change { resolvable_pending_conversation.messages.where(private: false).count })
    end

    it 'does not transition or enqueue a handoff activity message' do
      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('pending')
      expect(resolvable_pending_conversation.status_transitions).to be_empty
    end

    it 'does not create a captain inference handoff reporting event' do
      perform_enqueued_jobs do
        described_class.perform_now(inbox)
      end

      inference_event = ReportingEvent.find_by(
        conversation_id: resolvable_pending_conversation.id,
        name: 'conversation_captain_inference_handoff'
      )
      expect(inference_event).to be_nil
    end
  end

  context 'when an incomplete evaluation occurs outside business hours' do
    let(:handoff_reason) { 'Customer has not responded to clarifying question' }

    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return({ complete: false, reason: handoff_reason })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
      inbox.update!(working_hours_enabled: true, out_of_office_message: 'We are currently unavailable.')
    end

    it 'does not send an OOO handoff message for non-campaign conversations' do
      travel_to '01.11.2020 13:00'.to_datetime do
        resolvable_pending_conversation.update!(last_activity_at: 2.hours.ago)
        described_class.perform_now(inbox)

        ooo_message = resolvable_pending_conversation.messages.template.last
        expect(ooo_message).to be_nil
        expect(resolvable_pending_conversation.reload.status).to eq('pending')
      end
    end

    it 'does not send OOO message for campaign conversations' do
      campaign = create(:campaign, account: inbox.account, inbox: inbox)
      resolvable_pending_conversation.update!(campaign: campaign)

      travel_to '01.11.2020 13:00'.to_datetime do
        resolvable_pending_conversation.update!(last_activity_at: 2.hours.ago)
        described_class.perform_now(inbox)

        expect(resolvable_pending_conversation.messages.template).to be_empty
      end
    end

    it 'does not send OOO message during business hours' do
      travel_to '26.10.2020 10:00'.to_datetime do
        resolvable_pending_conversation.update!(last_activity_at: 2.hours.ago)
        described_class.perform_now(inbox)

        expect(resolvable_pending_conversation.messages.template).to be_empty
      end
    end
  end

  context 'when LLM evaluation fails' do
    before do
      allow(inbox.account).to receive(:feature_enabled?).and_call_original
      allow(inbox.account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      mock_service = instance_double(Captain::ConversationCompletionService)
      allow(mock_service).to receive(:perform).and_return({ complete: false, reason: 'API Error' })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(mock_service)
    end

    it 'does not force a handoff when evaluation fails' do
      described_class.perform_now(inbox)

      expect(resolvable_pending_conversation.reload.status).to eq('pending')
      expect(resolvable_pending_conversation.messages.outgoing).to be_empty
    end
  end

  it 'does not resolve conversations when auto-resolve is disabled at execution time' do
    inbox.account.update!(captain_auto_resolve_mode: 'disabled')

    expect do
      described_class.perform_now(inbox)
    end.not_to(change { resolvable_pending_conversation.reload.status })

    expect(resolvable_pending_conversation.reload.status).to eq('pending')
    expect(resolvable_pending_conversation.messages.outgoing).to be_empty
  end

  it 'falls back to disabled mode from legacy settings key' do
    inbox.account.update!(settings: inbox.account.settings.merge('captain_disable_auto_resolve' => true))

    expect do
      described_class.perform_now(inbox)
    end.not_to(change { resolvable_pending_conversation.reload.status })

    expect(resolvable_pending_conversation.reload.status).to eq('pending')
  end

  it 'does not resolve conversations when conversation workflow auto-resolve is disabled' do
    inbox.account.update!(auto_resolve_after: nil)

    expect do
      described_class.perform_now(inbox)
    end.not_to(change { resolvable_pending_conversation.reload.status })

    expect(resolvable_pending_conversation.reload.status).to eq('pending')
    expect(resolvable_pending_conversation.messages.outgoing).to be_empty
  end
end
