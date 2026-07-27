require 'rails_helper'

RSpec.describe Reminders::ExecuteService do
  describe '#perform' do
    it 'materializes a touch into a normal outgoing message' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        body: 'Hello {{contact.name}}'
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { conversation.messages.outgoing.count }.by(1)

      expect(touch.reload).to be_completed
      message = conversation.messages.outgoing.last
      expect(message.additional_attributes['touch_id']).to eq(touch.id)
      expect(message.content).to include(conversation.contact.name)
    end

    it 'materializes an agent touch using Captain-generated content' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short follow-up reminder',
        metadata: { 'captain_assistant_id' => assistant.id }
      )

      allow_any_instance_of(Reminders::CaptainGeneratedMessageService)
        .to receive(:perform)
        .and_return(
          content: 'Generated follow-up',
          assistant: assistant,
          captain_trace: { 'steps' => [] }
        )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(touch.reload).to be_completed
      expect(message.content).to eq('Generated follow-up')
      expect(message.additional_attributes['captain_trace']).to eq({ 'steps' => [] })
      expect(message.sender).to eq(assistant)
    end

    it 'does not materialize an agent touch when an incoming reply cancels it during Captain generation' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short follow-up reminder',
        auto_cancel_on_incoming: true,
        metadata: {
          'captain_assistant_id' => assistant.id,
          'auto_cancel_on_incoming_explicit' => true
        }
      )

      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform) do
        incoming = create(
          :message,
          account: conversation.account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming,
          private: false
        )
        Reminders::AutoCancelOnIncomingService.new(message: incoming).perform
        { content: 'Generated too late', assistant: assistant, captain_trace: {} }
      end

      expect do
        described_class.new(reminder: touch).perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_cancelled
      expect(touch.last_error).to eq(Reminders::AutoCancelOnIncomingService::CANCELLED_AFTER_INCOMING_REPLY)
    end

    it 'does not transition a wakeup conversation after an incoming reply cancels the touch during generation' do
      conversation = create(:conversation, status: :open)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        action_type: :ai_agent_wakeup,
        auto_cancel_on_incoming: true,
        metadata: {
          'captain_assistant_id' => assistant.id,
          'auto_cancel_on_incoming_explicit' => true
        }
      )
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform) do
        incoming = create(
          :message,
          account: conversation.account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming,
          private: false
        )
        Reminders::AutoCancelOnIncomingService.new(message: incoming).perform
        { content: 'Generated too late', assistant: assistant, captain_trace: {} }
      end

      expect do
        described_class.new(reminder: touch).perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_cancelled
      expect(conversation.reload).to be_open
    end

    it 'does not mark a reminder failed after a concurrent reschedule wins during generation' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        instructions: 'Generate a follow-up',
        metadata: { 'captain_assistant_id' => assistant.id }
      )
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform) do
        Reminder.where(id: touch.id).update_all(
          status: Reminder.statuses[:pending],
          processing_started_at: nil,
          updated_at: 1.second.from_now
        )
        raise 'generation failed after reschedule'
      end

      expect do
        described_class.new(reminder: touch).perform
      end.to raise_error(RuntimeError, 'generation failed after reschedule')

      expect(touch.reload).to be_pending
      expect(touch.last_error).to be_nil
    end

    it 'does not send a stale generated payload after the processing reminder is edited concurrently' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        instructions: 'Generate the original follow-up',
        metadata: { 'captain_assistant_id' => assistant.id }
      )
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform) do
        Reminder.where(id: touch.id).update_all(
          instructions: 'Generate the edited follow-up instead',
          updated_at: 1.second.from_now
        )
        { content: 'Stale generated content', assistant: assistant, captain_trace: {} }
      end

      expect do
        described_class.new(reminder: touch).perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_pending
      expect(touch.processing_started_at).to be_nil
    end

    it 'does not reset a newer processing claim when an older worker finishes generation' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        text_mode: :agent,
        instructions: 'Generate the original follow-up',
        metadata: { 'captain_assistant_id' => assistant.id }
      )
      touch.mark_processing!
      newer_claim = 1.second.from_now
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform) do
        Reminder.where(id: touch.id).update_all(
          status: Reminder.statuses[:processing],
          processing_started_at: newer_claim,
          metadata: touch.metadata.merge('processing_claim_token' => 'newer-claim'),
          updated_at: newer_claim
        )
        { content: 'Old worker content', assistant: assistant, captain_trace: {} }
      end

      expect do
        described_class.new(reminder: touch).perform
      end.not_to(change { conversation.messages.outgoing.count })

      touch.reload
      expect(touch).to be_processing
      expect(touch.processing_claim_token).to eq('newer-claim')
      expect(touch.processing_started_at).to be_within(1.second).of(newer_claim)
    end

    it 'resumes an already materialized message without creating a duplicate' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        body: 'Resume this message'
      )
      active_claim = touch.mark_processing!
      message = create(
        :message,
        account: conversation.account,
        inbox: conversation.inbox,
        conversation: conversation,
        message_type: :outgoing,
        skip_send_reply: true,
        additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
      )
      touch.mark_delivery_materialized!(message.id)
      allow(Reminders::MessageMaterializer).to receive(:new).and_call_original
      expect(Reminders::DeliverMaterializedMessageJob)
        .to receive(:perform_later)
        .with(touch.id, message.id, active_claim)
        .once
        .and_call_original

      expect do
        described_class.new(reminder: touch, processing_claim: active_claim).perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(Reminders::MessageMaterializer).not_to have_received(:new)
      expect(touch.reload).to be_completed
    end

    it 'resumes under the final lock when another worker materialized the same claim' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        body: 'Parallel same-claim message'
      )
      active_claim = touch.mark_processing!
      second_worker = described_class.new(reminder: touch, processing_claim: active_claim)
      message = create(
        :message,
        account: conversation.account,
        inbox: conversation.inbox,
        conversation: conversation,
        message_type: :outgoing,
        skip_send_reply: true,
        additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
      )
      touch.mark_delivery_materialized!(message.id)
      allow(Reminders::MessageMaterializer).to receive(:new).and_call_original

      expect do
        second_worker.perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(Reminders::MessageMaterializer).not_to have_received(:new)
      expect(touch.reload).to be_completed
    end

    it 'marks the touch failed when delivery enqueue fails after message materialization' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        body: 'Queue this message'
      )
      allow(Reminders::DeliverMaterializedMessageJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')
      allow(SendReplyJob).to receive(:perform_later).and_call_original

      expect do
        described_class.new(reminder: touch).perform
      end.to raise_error(StandardError, 'redis unavailable')

      expect(touch.reload).to be_failed
      expect(touch).not_to be_completed
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(touch.metadata['delivery_materialized_message_id']).to eq(conversation.messages.outgoing.last.id)
      expect(SendReplyJob).not_to have_received(:perform_later)
    end

    it 'sends an agent touch from the Captain assistant, not the human message_sender' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      human = create(:user, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short follow-up reminder',
        owner: human,
        metadata: { 'captain_assistant_id' => assistant.id }
      )

      allow_any_instance_of(Reminders::CaptainGeneratedMessageService)
        .to receive(:perform)
        .and_return(content: 'Generated follow-up', assistant: assistant, captain_trace: {})

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(message.sender).to eq(assistant)
      expect(message.sender).not_to eq(human)
    end

    it 'sends a non-agent touch from the human message_sender' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        body: 'Plain reminder'
      )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(message.sender).to eq(touch.reload.message_sender)
    end

    it 'wakes up Captain and creates an assistant message for ai_agent_wakeup touches' do
      conversation = create(:conversation, status: :open)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        action_type: :ai_agent_wakeup,
        metadata: { 'captain_assistant_id' => assistant.id }
      )

      allow_any_instance_of(Reminders::CaptainGeneratedMessageService)
        .to receive(:perform)
        .and_return(
          content: 'Captain wakeup message',
          assistant: assistant,
          captain_trace: { 'steps' => ['generated'] }
        )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(touch.reload).to be_completed
      expect(conversation.reload).to be_pending
      expect(message.sender).to eq(assistant)
      expect(message.content).to eq('Captain wakeup message')
    end

    it 'creates the next recurring touch after successful execution' do
      conversation = create(:conversation)
      scheduled_at = Time.zone.parse('2026-04-13 13:00:00 UTC')
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        scheduled_at: scheduled_at,
        repeat_mode: :weekly,
        repeat_until_at: scheduled_at + 1.month,
        body: 'Weekly check-in'
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { conversation.account.reminders.count }.by(1)

      next_touch = conversation.account.reminders.where.not(id: touch.id).order(:created_at).last

      expect(touch.reload).to be_completed
      expect(next_touch).to be_present
      expect(next_touch).to be_pending
      expect(next_touch.repeat_mode).to eq('weekly')
      expect(next_touch.scheduled_at.to_i).to eq((scheduled_at + 1.week).to_i)
    end

    it 'delivers a personal reminder through telegram personal using the shared target resolution path' do
      account = create(:account)
      inbox = create(:channel_telegram_personal, account: account).inbox
      contact = create(
        :contact,
        account: account,
        additional_attributes: { 'social_telegram_user_id' => 4242 }
      )
      touch = Reminder.create!(
        account: account,
        creator: create(:user, account: account, role: :administrator),
        owner: account.administrators.first,
        status: :processing,
        body: 'Telegram follow-up',
        target_inbox: inbox,
        target_contact: contact,
        conversation: nil,
        remindable: nil,
        target_conversation: nil,
        target_contact_inbox: nil
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { inbox.messages.outgoing.count }.by(1)

      expect(touch.reload).to be_completed
      expect(touch.target_conversation).to be_present
      expect(touch.target_contact_inbox).to be_present
      expect(touch.target_conversation.contact).to eq(contact)
      expect(touch.target_conversation.contact_inbox.source_id).to eq('4242')
    end

    it 'fails at execution time when a WhatsApp free_text touch no longer has an open reply window' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      touch = nil
      travel_to(Time.zone.parse('2026-05-05 10:00:00 UTC')) do
        create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming')
        touch = create(
          :reminder,
          account: account,
          touch_conversation: conversation,
          conversation: conversation,
          remindable: conversation,
          status: :pending,
          scheduled_at: 1.hour.from_now,
          body: 'This should not be sent outside the window'
        )
      end

      travel_to(Time.zone.parse('2026-05-06 11:01:00 UTC')) do
        touch.update_columns(status: Reminder.statuses[:processing], scheduled_at: Time.current, updated_at: Time.current)

        expect do
          described_class.new(reminder: touch).perform
        end.to raise_error(ArgumentError, /approved channel_template/)

        expect(touch.reload).to be_failed
        expect(conversation.messages.outgoing.count).to eq(0)
      end
    end

    it 'reschedules a due touch into the first 30 minutes of the next inbox working window' do
      travel_to(Time.zone.parse('2026-05-02 23:00:00 UTC')) do
        account = create(:account)
        inbox = create(:inbox, account: account, timezone: 'UTC', working_hours_enabled: true)
        contact = create(:contact, account: account)
        contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
        conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
        touch = create(
          :reminder,
          account: account,
          touch_conversation: conversation,
          conversation: conversation,
          remindable: conversation,
          status: :processing,
          scheduled_at: 5.minutes.ago,
          body: 'Wait for business hours'
        )

        expect do
          described_class.new(reminder: touch).perform
        end.not_to(change { conversation.messages.outgoing.count })

        touch.reload
        expect(touch).to be_pending
        expect(touch.scheduled_at).to be_between(
          Time.zone.parse('2026-05-04 09:00:00 UTC'),
          Time.zone.parse('2026-05-04 09:30:00 UTC')
        ).inclusive
        expect(touch.metadata).to include('rescheduled_by_working_hours' => true, 'working_hours_reschedule_reason' => 'outside_working_hours')
      end
    end

    it 'cancels an automation touch instead of sending or rescheduling when a same-contact campaign is blocking' do
      account = create(:account)
      inbox = create(:inbox, account: account, working_hours_enabled: false)
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      campaign = create(:campaign, account: account, inbox: inbox)
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)
      touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        body: 'Automation follow-up',
        metadata: { 'touch_source' => 'automation', 'automation_rule_id' => 123 }
      )

      expect do
        described_class.new(reminder: touch).perform
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_cancelled
      expect(touch.last_error).to eq('отменен из-за рассылки')
      expect(touch.metadata).to include('cancelled_via' => 'campaign_conflict_policy', 'campaign_conflict_campaign_id' => campaign.id)
    end

    it 'executes a WhatsApp channel_template touch and stores template delivery metadata' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      template_params = {
        name: 'sample_shipping_confirmation',
        language: 'en_US',
        namespace: '23423423_2342423_324234234_2343224',
        processed_params: { '1' => '2' }
      }
      touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        content_kind: :channel_template,
        body: nil,
        template_params: template_params
      )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(touch.reload).to be_completed
      expect(message.additional_attributes['template_params']).to include('name' => 'sample_shipping_confirmation')
      expect(message.additional_attributes['delivery_policy']).to include('delivery_mode' => 'channel_template', 'requires_template' => true)
    end

    context 'when a channel template uses appointment fields' do
      let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
      let(:whatsapp_channel) do
        create(
          :channel_whatsapp,
          account: account,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
      end
      let(:contact) { create(:contact, account: account) }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox) }
      let(:conversation) do
        create(
          :conversation,
          account: account,
          inbox: whatsapp_channel.inbox,
          contact: contact,
          contact_inbox: contact_inbox
        )
      end
      let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
      let(:appointment) do
        create(
          :scheduling_appointment,
          account: account,
          resource: resource,
          contact: contact,
          conversation: nil,
          starts_at: Time.utc(2026, 7, 13, 4, 5),
          ends_at: Time.utc(2026, 7, 13, 4, 35)
        )
      end
      let(:second_param) { '[Время](field://appointment.start_time)' }
      let(:appointment_reminder) do
        create(
          :reminder,
          account: account,
          conversation: conversation,
          target_conversation: conversation,
          target_inbox: whatsapp_channel.inbox,
          target_contact: contact,
          target_contact_inbox: contact_inbox,
          remindable: appointment,
          status: :processing,
          content_kind: :channel_template,
          body: nil,
          template_params: {
            name: 'appointment_scheduled_confirmation',
            language: 'ru',
            processed_params: {
              body: {
                '1' => '[Дата](field://appointment.start_date)',
                '2' => second_param,
                '3' => '14:00'
              }
            }
          }
        )
      end

      before do
        account.enable_features!('scheduling')
        whatsapp_channel.update!(
          message_templates: [
            {
              'name' => 'appointment_scheduled_confirmation',
              'language' => 'ru',
              'status' => 'APPROVED',
              'parameter_format' => 'POSITIONAL',
              'components' => [{ 'type' => 'BODY', 'text' => 'Запись {{1}} в {{2}}, результат до {{3}}' }]
            }
          ]
        )
      end

      it 'renders the template params without appointment conversation context' do
        described_class.new(reminder: appointment_reminder).perform

        message = conversation.messages.outgoing.last
        expect(message.additional_attributes.dig('template_params', 'processed_params', 'body')).to eq(
          '1' => '13.07.2026',
          '2' => '09:05',
          '3' => '14:00'
        )

        _, _, _, meta_components = Whatsapp::TemplateProcessorService.new(
          channel: whatsapp_channel,
          template_params: message.additional_attributes['template_params'],
          message: message
        ).call
        expect(meta_components.dig(0, :parameters).pluck(:text)).to eq(['13.07.2026', '09:05', '14:00'])
      end

      context 'when a rendered required param is blank' do
        let(:second_param) { '[Пусто](field://appointment.custom_attributes.unknown)' }

        it 'fails before message materialization' do
          expect do
            described_class.new(reminder: appointment_reminder).perform
          end.to raise_error(ArgumentError, /Template params missing required values: body.2/)

          expect(appointment_reminder.reload).to be_failed
          expect(conversation.messages.outgoing.count).to eq(0)
        end
      end
    end

    it 'fails a touch whose channel has no outbound send service instead of silently not delivering' do
      account = create(:account)
      allow_any_instance_of(Channel::Voice).to receive(:provision_twilio_on_create)
      voice_inbox = create(:channel_voice, account: account).inbox
      contact = create(:contact, account: account)
      voice_conversation = create(:conversation, account: account, inbox: voice_inbox, contact: contact)
      reminder = build(:reminder, account: account, conversation: voice_conversation, remindable: voice_conversation,
                                  body: 'Should not silently fail')

      expect do
        described_class.new(reminder: reminder).perform
      end.to raise_error(ArgumentError, /does not support outbound message delivery/)
    end
  end
end
