require 'rails_helper'

RSpec.describe DeleteObjectJob, type: :job do
  describe '#perform' do
    context 'when object is heavy (Inbox)' do
      let!(:account) { create(:account) }
      let!(:inbox) { create(:inbox, account: account) }

      before do
        create_list(:conversation, 3, account: account, inbox: inbox)
        ReportingEvent.create!(account: account, inbox: inbox, name: 'inbox_metric', value: 1.0)
      end

      it 'enqueues on the low queue' do
        expect { described_class.perform_later(inbox) }
          .to have_enqueued_job(described_class).with(inbox).on_queue('low')
      end

      it 'pre-deletes heavy associations and then destroys the object' do
        conv_ids = inbox.conversations.pluck(:id)
        ci_ids = inbox.contact_inboxes.pluck(:id)
        contact_ids = inbox.contacts.pluck(:id)
        re_ids = inbox.reporting_events.pluck(:id)

        described_class.perform_now(inbox)

        # Reload associations to ensure database state is current
        expect(Conversation.where(id: conv_ids).reload).to be_empty
        expect(ContactInbox.where(id: ci_ids).reload).to be_empty
        expect(ReportingEvent.where(id: re_ids).reload).to be_empty
        # Contacts should not be deleted for inbox destroy
        expect(Contact.where(id: contact_ids).reload).not_to be_empty
        expect { inbox.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'preserves WhatsApp inbox data when fail-closed webhook teardown aborts deletion', :aggregate_failures do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        conversation = create(:conversation, account: whatsapp_channel.account, inbox: whatsapp_inbox)
        teardown_service = instance_double(Whatsapp::WebhookTeardownService)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(whatsapp_channel).and_return(teardown_service)
        allow(teardown_service).to receive(:perform).and_raise(
          Whatsapp::WebhookTeardownService::WebhookTeardownError,
          'Meta unsubscribe failed (100/33)'
        )
        attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: attempt_id)

        expect { described_class.perform_now(whatsapp_inbox, nil, nil, attempt_id) }
          .not_to raise_error
        expect(teardown_service).to have_received(:perform).once

        expect(whatsapp_inbox.reload).not_to be_deleting
        expect(whatsapp_inbox.deletion_attempt_id).to be_nil
        expect(whatsapp_inbox.deletion_recovery_payload).to include(
          status: 'failed',
          remote_outcome: 'unknown',
          error_code: 'remote_teardown_failed'
        )
        expect(Channel::Whatsapp.exists?(whatsapp_channel.id)).to be(true)
        expect(Conversation.exists?(conversation.id)).to be(true)
        expect(whatsapp_channel.reload.inbox_deletion_recovery).to include(
          'attempt_id' => attempt_id,
          'status' => 'failed',
          'remote_outcome' => 'unknown'
        )
      end

      it 'destroys the WhatsApp channel before purging its inbox data' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        conversation = create(:conversation, account: whatsapp_channel.account, inbox: whatsapp_inbox)
        teardown_service = instance_double(Whatsapp::WebhookTeardownService, perform: true)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(whatsapp_channel).and_return(teardown_service)
        attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: attempt_id)

        described_class.perform_now(whatsapp_inbox, nil, nil, attempt_id)

        expect(Channel::Whatsapp.exists?(whatsapp_channel.id)).to be(false)
        expect(Inbox.exists?(whatsapp_inbox.id)).to be(false)
        expect(Conversation.exists?(conversation.id)).to be(false)
      end

      it 'preserves the legacy three-argument deletion path for non-Cloud WhatsApp' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'default',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        conversation = create(:conversation, account: whatsapp_channel.account, inbox: whatsapp_inbox)

        described_class.perform_now(whatsapp_inbox)

        expect(Channel::Whatsapp.exists?(whatsapp_channel.id)).to be(false)
        expect(Inbox.exists?(whatsapp_inbox.id)).to be(false)
        expect(Conversation.exists?(conversation.id)).to be(false)
      end

      it 'does not let a stale legacy or older generation retry delete a recovered inbox' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        conversation = create(:conversation, account: whatsapp_channel.account, inbox: whatsapp_inbox)
        teardown_service = instance_double(Whatsapp::WebhookTeardownService)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(whatsapp_channel).and_return(teardown_service)
        allow(teardown_service).to receive(:perform).and_raise(
          Whatsapp::WebhookTeardownService::WebhookTeardownError,
          'unsubscribe failed'
        )
        failed_attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: failed_attempt_id)
        expect do
          described_class.perform_now(whatsapp_inbox, nil, nil, failed_attempt_id)
        end.not_to raise_error
        expect(teardown_service).to have_received(:perform).once

        expect do
          described_class.perform_now(whatsapp_inbox)
          described_class.perform_now(whatsapp_inbox, nil, nil, failed_attempt_id)
        end.not_to(change { Conversation.exists?(conversation.id) })
        expect(whatsapp_inbox.reload).not_to be_deleting
        expect(whatsapp_inbox.deletion_attempt_id).to be_nil
        expect(whatsapp_channel.reload.inbox_deletion_failed?).to be(true)
      end

      it 'does not restore a failed teardown while its account is pending deletion' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: attempt_id)
        whatsapp_inbox.account.update!(
          custom_attributes: whatsapp_inbox.account.custom_attributes.to_h.merge(
            'marked_for_deletion_at' => Time.current.iso8601
          )
        )
        teardown_service = instance_double(Whatsapp::WebhookTeardownService)
        allow(teardown_service).to receive(:perform)
          .and_raise(Whatsapp::WebhookTeardownService::WebhookTeardownError, 'unsubscribe failed')
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(whatsapp_channel).and_return(teardown_service)

        expect do
          described_class.perform_now(whatsapp_inbox, nil, nil, attempt_id)
        end.to raise_error(Whatsapp::WebhookTeardownService::WebhookTeardownError)

        expect(whatsapp_inbox.reload).to be_deleting
        expect(whatsapp_inbox.deletion_attempt_id).to eq(attempt_id)
        expect(whatsapp_channel.reload.inbox_deletion_recovery).to include(
          'attempt_id' => attempt_id,
          'status' => 'pending'
        )
      end

      it 'keeps a failed recovery visible until an explicit successful reauthorization resolves it' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: attempt_id)
        whatsapp_channel.mark_inbox_deletion_failed!(attempt_id: attempt_id, failed_at: Time.current)
        whatsapp_inbox.update!(deleting_at: nil, deletion_attempt_id: nil)

        expect(whatsapp_inbox.deletion_recovery_failed?).to be(true)
        expect(whatsapp_inbox.resolve_failed_whatsapp_deletion_recovery!).to be(true)
        expect(whatsapp_channel.reload.inbox_deletion_recovery).to include(
          'status' => 'resolved',
          'attempt_id' => attempt_id,
          'remote_outcome' => 'subscription_restored',
          'last_failure' => hash_including(
            'attempt_id' => attempt_id,
            'error_code' => 'remote_teardown_failed'
          )
        )
        expect(whatsapp_inbox.deletion_recovery_failed?).to be(false)

        expect do
          described_class.perform_now(whatsapp_inbox)
        end.not_to(change { Inbox.exists?(whatsapp_inbox.id) })
        expect(whatsapp_inbox.reload).not_to be_deleting
      end

      it 'does not resolve a newer pending deletion after a reauthorization callback' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        first_attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: first_attempt_id)
        whatsapp_channel.mark_inbox_deletion_failed!(attempt_id: first_attempt_id, failed_at: Time.current)
        whatsapp_inbox.update!(deleting_at: nil, deletion_attempt_id: nil)
        expect(whatsapp_inbox.resolve_failed_whatsapp_deletion_recovery!).to be(true)

        next_attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: next_attempt_id)

        expect(whatsapp_inbox.resolve_failed_whatsapp_deletion_recovery!).to be(false)
        expect(whatsapp_channel.reload.inbox_deletion_recovery).to include(
          'status' => 'pending',
          'attempt_id' => next_attempt_id
        )
      end

      it 'leaves a deletion resumable after channel teardown succeeds but inbox purge fails' do
        whatsapp_channel = create(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        whatsapp_inbox = whatsapp_channel.inbox
        conversation = create(:conversation, account: whatsapp_channel.account, inbox: whatsapp_inbox)
        teardown_service = instance_double(Whatsapp::WebhookTeardownService, perform: true)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(whatsapp_channel).and_return(teardown_service)
        attempt_id = SecureRandom.uuid
        whatsapp_inbox.mark_pending_deletion!(attempt_id: attempt_id)
        first_delivery = described_class.new
        allow(first_delivery).to receive(:destroy_with_prepared_dependencies).and_raise(
          StandardError,
          'injected purge interruption'
        )

        expect do
          first_delivery.perform(whatsapp_inbox, nil, nil, attempt_id)
        end.to raise_error(StandardError, 'injected purge interruption')

        expect(Channel::Whatsapp.exists?(whatsapp_channel.id)).to be(false)
        expect(whatsapp_inbox.reload).to be_deleting
        expect(whatsapp_inbox.deletion_attempt_id).to eq(attempt_id)
        expect(Conversation.exists?(conversation.id)).to be(true)

        described_class.perform_now(whatsapp_inbox, nil, nil, attempt_id)

        expect(Inbox.exists?(whatsapp_inbox.id)).to be(false)
        expect(Conversation.exists?(conversation.id)).to be(false)
      end

      it 'keeps telephony call audit records when destroying an inbox' do
        conversation = create(:conversation, account: account, inbox: inbox)
        call_session = create(
          :telephony_call_session,
          account: account,
          conversation: conversation,
          contact: conversation.contact,
          inbox: inbox,
          external_call_ref: 'delete-inbox-call-ref'
        )

        described_class.perform_now(inbox)

        expect(call_session.reload).to have_attributes(
          conversation_id: nil,
          inbox_id: nil,
          number_binding_id: nil,
          contact_id: conversation.contact_id
        )
      end

      it 'detaches conversation-scoped touches and CRM records before destroying an inbox' do
        conversation = create(:conversation, account: account, inbox: inbox)
        reminder = create(:reminder, account: account, touch_conversation: conversation)
        delivery_message = create(:message, account: account, inbox: inbox, conversation: conversation)
        resolved_message = create(:message, account: account, inbox: inbox, conversation: conversation)
        confirmation_request = create(
          :confirmation_request,
          account: account,
          conversation: conversation,
          inbox: inbox,
          delivery_message: delivery_message,
          resolved_message: resolved_message
        )
        deal = create(:crm_deal, account: account, originating_conversation: conversation)
        task = create(:crm_task, account: account, originating_conversation: conversation)
        appointment = create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation)

        described_class.perform_now(inbox)

        expect { conversation.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(reminder.reload).to have_attributes(
          conversation_id: nil,
          target_conversation_id: nil,
          target_inbox_id: nil,
          target_contact_inbox_id: nil,
          remindable_id: nil,
          remindable_type: nil
        )
        expect(confirmation_request.reload).to have_attributes(
          conversation_id: nil,
          delivery_message_id: nil,
          inbox_id: nil,
          resolved_message_id: nil
        )
        expect(deal.reload.originating_conversation_id).to be_nil
        expect(task.reload.originating_conversation_id).to be_nil
        expect(appointment.reload.conversation_id).to be_nil
      end

      it 'removes a voice inbox while preserving telephony call sessions and events as audit records' do
        voice_channel = create(:channel_voice, :sipuni, account: account, phone_number: '+15551239999')
        voice_inbox = voice_channel.inbox
        number_binding = voice_inbox.telephony_number_binding
        routing_policy = number_binding.routing_policy
        conversation = create(:conversation, account: account, inbox: voice_inbox)
        call_session = create(
          :telephony_call_session,
          account: account,
          conversation: conversation,
          contact: conversation.contact,
          inbox: voice_inbox,
          number_binding: number_binding,
          external_call_ref: 'delete-voice-inbox-call-ref'
        )
        event = Telephony::Event.create!(
          account: account,
          call_session: call_session,
          event_key: 'delete-voice-inbox-event',
          event_type: 'session_completed',
          payload: {},
          status: 'processed'
        )

        described_class.perform_now(voice_inbox)

        expect { voice_inbox.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect { voice_channel.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(Telephony::NumberBinding.exists?(number_binding.id)).to be(false)
        expect(Telephony::RoutingPolicy.exists?(routing_policy.id)).to be(false)
        expect(call_session.reload).to have_attributes(
          conversation_id: nil,
          inbox_id: nil,
          number_binding_id: nil,
          contact_id: conversation.contact_id
        )
        expect(event.reload.call_session_id).to eq(call_session.id)
      end
    end

    context 'when object is a conversation with telephony call sessions' do
      let!(:account) { create(:account) }
      let!(:conversation) { create(:conversation, account: account) }

      it 'keeps telephony call audit records when destroying the conversation' do
        call_session = create(
          :telephony_call_session,
          account: account,
          conversation: conversation,
          contact: conversation.contact,
          inbox: conversation.inbox,
          external_call_ref: 'delete-conversation-call-ref'
        )

        described_class.perform_now(conversation)

        expect(call_session.reload).to have_attributes(
          conversation_id: nil,
          inbox_id: conversation.inbox_id,
          contact_id: conversation.contact_id
        )
      end

      it 'detaches conversation-scoped dependencies before destroying the conversation' do
        reminder = create(:reminder, account: account, touch_conversation: conversation)
        post_delivery_reminder = create(
          :reminder,
          account: account,
          touch_conversation: conversation,
          conversation: conversation,
          remindable: conversation,
          post_delivery_action: Reminder::POST_DELIVERY_ACTION_RESOLVE_CONVERSATION
        )
        delivery_message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation)
        resolved_message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation)
        confirmation_request = create(
          :confirmation_request,
          account: account,
          conversation: conversation,
          inbox: conversation.inbox,
          delivery_message: delivery_message,
          resolved_message: resolved_message
        )
        deal = create(:crm_deal, account: account, originating_conversation: conversation)
        task = create(:crm_task, account: account, originating_conversation: conversation)
        appointment = create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation)
        assignment_policy = create(:assignment_policy, account: account)
        assigned_user = create(:user, account: account, role: :agent)
        quota_usage = create(
          :assignment_quota_usage,
          account: account,
          user: assigned_user,
          contact: conversation.contact,
          conversation: conversation,
          assignment_policy: assignment_policy
        )
        decision_log = create(
          :assignment_decision_log,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          assignment_policy: assignment_policy,
          assigned_user: assigned_user
        )

        described_class.perform_now(conversation)

        expect { conversation.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(reminder.reload).to have_attributes(
          conversation_id: nil,
          target_conversation_id: nil,
          remindable_id: nil,
          remindable_type: nil
        )
        expect(post_delivery_reminder.reload).to have_attributes(
          conversation_id: nil,
          target_conversation_id: nil,
          remindable_id: nil,
          remindable_type: nil,
          post_delivery_action: nil
        )
        expect(confirmation_request.reload).to have_attributes(
          conversation_id: nil,
          delivery_message_id: nil,
          inbox_id: conversation.inbox_id,
          resolved_message_id: nil
        )
        expect(deal.reload.originating_conversation_id).to be_nil
        expect(task.reload.originating_conversation_id).to be_nil
        expect(appointment.reload.conversation_id).to be_nil
        expect(quota_usage.reload.conversation_id).to be_nil
        expect(AssignmentDecisionLog.exists?(decision_log.id)).to be(false)
      end

      it 'deletes status transitions before destroying the conversation' do
        transition_ids = Array.new(3) do |index|
          ConversationStatusTransition.create!(
            account: account,
            conversation: conversation,
            from_status: 'open',
            to_status: 'resolved',
            source: 'manual',
            metadata: { index: index }
          ).id
        end

        described_class.perform_now(conversation)

        expect { conversation.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(ConversationStatusTransition.where(id: transition_ids)).to be_empty
      end

      it 'removes the empty communication thread and detaches CRM deals after destroying the last conversation' do
        thread = create(:communication_thread, account: account, contact: conversation.contact)
        create(
          :communication_thread_conversation,
          account: account,
          communication_thread: thread,
          conversation: conversation,
          inbox: conversation.inbox,
          contact_inbox: conversation.contact_inbox,
          primary: true
        )
        deal = create(:crm_deal, account: account, originating_communication_thread: thread)

        described_class.perform_now(conversation)

        expect(CommunicationThread.exists?(thread.id)).to be(false)
        expect(deal.reload.originating_communication_thread_id).to be_nil
      end

      it 'keeps a communication thread when other linked conversations remain' do
        other_conversation = create(:conversation, account: account, contact: conversation.contact)
        thread = create(:communication_thread, account: account, contact: conversation.contact)
        create(
          :communication_thread_conversation,
          account: account,
          communication_thread: thread,
          conversation: conversation,
          inbox: conversation.inbox,
          contact_inbox: conversation.contact_inbox,
          primary: true
        )
        create(
          :communication_thread_conversation,
          account: account,
          communication_thread: thread,
          conversation: other_conversation,
          inbox: other_conversation.inbox,
          contact_inbox: other_conversation.contact_inbox
        )
        deal = create(:crm_deal, account: account, originating_communication_thread: thread)

        described_class.perform_now(conversation)

        expect(CommunicationThread.exists?(thread.id)).to be(true)
        expect(deal.reload.originating_communication_thread_id).to eq(thread.id)
      end

      it 'keeps communication thread links when conversation destruction fails' do
        thread = create(:communication_thread, account: account, contact: conversation.contact)
        link = create(
          :communication_thread_conversation,
          account: account,
          communication_thread: thread,
          conversation: conversation,
          inbox: conversation.inbox,
          contact_inbox: conversation.contact_inbox,
          primary: true
        )
        allow(conversation).to receive(:destroy!).and_raise(StandardError, 'blocked deletion')

        expect { described_class.perform_now(conversation) }.to raise_error(StandardError, 'blocked deletion')
        expect(CommunicationThread.exists?(thread.id)).to be(true)
        expect(CommunicationThreadConversation.exists?(link.id)).to be(true)
      end
    end

    context 'when object is a WhatsApp Web inbox' do
      let!(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
      let!(:channel) { create(:channel_whatsapp_web, account: account) }
      let!(:inbox) { channel.inbox }
      let!(:conversation) { create(:conversation, account: account, inbox: inbox) }

      around do |example|
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          example.run
        end
      end

      it 'tears down the remote instance before destroying local records' do
        teardown_started = false
        stub_request(:delete, "https://evolution.example.com/instance/delete/#{channel.instance_name}")
          .with(headers: { 'Apikey' => 'test-api-key' }).to_return do
            expect(Conversation.exists?(conversation.id)).to be(true) unless teardown_started
            teardown_started = true
            { status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' } }
          end
        expect(inbox).to receive(:destroy!).and_wrap_original do |method, *args|
          expect(teardown_started).to be(true)
          method.call(*args)
        end

        described_class.perform_now(inbox)

        expect(Channel::WhatsappWeb.exists?(channel.id)).to be(false)
        expect(Inbox.exists?(inbox.id)).to be(false)
        expect(Conversation.exists?(conversation.id)).to be(false)
      end
    end

    context 'when object is a Telegram Personal inbox' do
      let!(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
      let!(:channel) { create(:channel_telegram_personal, account: account) }
      let!(:inbox) { channel.inbox }
      let!(:conversation) { create(:conversation, account: account, inbox: inbox) }

      around do |example|
        with_modified_env(
          'TELEGRAM_PERSONAL_GATEWAY_URL' => 'http://telegram-personal-gateway.test',
          'TELEGRAM_PERSONAL_GATEWAY_TOKEN' => 'test-gateway-token'
        ) do
          example.run
        end
      end

      it 'tears down the gateway runtime before destroying local records' do
        teardown_started = false
        stub_request(:delete, "http://telegram-personal-gateway.test/internal/channels/#{channel.id}")
          .with(headers: { 'Authorization' => 'Bearer test-gateway-token' }).to_return do
            expect(Conversation.exists?(conversation.id)).to be(true)
            teardown_started = true
            { status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' } }
          end
        expect(inbox).to receive(:destroy!).and_wrap_original do |method, *args|
          expect(teardown_started).to be(true)
          method.call(*args)
        end

        described_class.perform_now(inbox)

        expect(Channel::TelegramPersonal.exists?(channel.id)).to be(false)
        expect(Inbox.exists?(inbox.id)).to be(false)
        expect(Conversation.exists?(conversation.id)).to be(false)
      end
    end

    context 'when object is heavy (Account)' do
      let!(:account) { create(:account) }
      let!(:inbox1) { create(:inbox, account: account) }
      let!(:inbox2) { create(:inbox, account: account) }

      before do
        create_list(:conversation, 2, account: account, inbox: inbox1)
        create_list(:conversation, 1, account: account, inbox: inbox2)
        ReportingEvent.create!(account: account, name: 'acct_metric', value: 2.5)
        ReportingEvent.create!(account: account, inbox: inbox1, name: 'acct_inbox_metric', value: 3.5)
      end

      it 'pre-deletes conversations, contacts, inboxes and reporting events and then destroys the account' do
        conv_ids = account.conversations.pluck(:id)
        contact_ids = account.contacts.pluck(:id)
        inbox_ids = account.inboxes.pluck(:id)
        re_ids = account.reporting_events.pluck(:id)

        described_class.perform_now(account)

        # Reload associations to ensure database state is current
        expect(Conversation.where(id: conv_ids).reload).to be_empty
        expect(Contact.where(id: contact_ids).reload).to be_empty
        expect(Inbox.where(id: inbox_ids).reload).to be_empty
        expect(ReportingEvent.where(id: re_ids).reload).to be_empty
        expect { account.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when object is regular (Label)' do
      it 'just destroys the object' do
        label = create(:label)

        described_class.perform_now(label)

        expect { label.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
