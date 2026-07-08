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
