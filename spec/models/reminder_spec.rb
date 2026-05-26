require 'rails_helper'

RSpec.describe Reminder do
  describe 'relative scheduling' do
    it 'materializes scheduled_at from the relative anchor' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq((conversation.created_at + 1.hour).to_i)
    end

    it 'materializes touch.created_at relative scheduling from current time for new touches' do
      freeze_time do
        conversation = create(:conversation)
        reminder = build(
          :reminder,
          account: conversation.account,
          touch_conversation: conversation,
          conversation: conversation,
          remindable: conversation,
          timing_mode: :relative,
          relative_anchor: 'touch.created_at',
          relative_offset_seconds: 180,
          scheduled_at: nil
        )

        reminder.validate

        expect(reminder.scheduled_at).to eq(3.minutes.from_now)
        expect(reminder).to be_pending
      end
    end

    it 'does not materialize missing last incoming message anchors' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.last_incoming_message_at',
        relative_offset_seconds: 180,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at).to be_nil
      expect(reminder).to be_draft
    end

    it 'materializes scheduled_at from the last outgoing conversation message' do
      conversation = create(:conversation)
      outgoing_message = create(
        :message,
        account: conversation.account,
        conversation: conversation,
        inbox: conversation.inbox,
        message_type: :outgoing,
        private: false
      )
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.last_outgoing_message_at',
        relative_offset_seconds: 1800,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (outgoing_message.created_at + 30.minutes).to_i
      )
    end

    it 'materializes scheduled_at from waiting since when the conversation is awaiting a reply' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.waiting_since',
        relative_offset_seconds: 900,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (conversation.waiting_since + 15.minutes).to_i
      )
    end
  end

  describe 'duplicate protection' do
    it 'blocks duplicate open touches with the same fingerprint' do
      conversation = create(:conversation)
      scheduled_at = 1.hour.from_now.change(usec: 0)
      create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )
      duplicate = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base]).to include('An open touch with the same content already exists')
    end
  end

  describe 'official WhatsApp delivery policy' do
    it 'rejects manual free-text touches when the scheduled delivery is outside the 24-hour window' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      reminder = build(
        :reminder,
        account: account,
        touch_conversation: conversation,
        scheduled_at: 25.hours.from_now,
        body: 'Future free text'
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:base]).to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
    end

    it 'treats AI-generated touch instructions as free text for the official WhatsApp window policy' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      reminder = build(
        :reminder,
        account: account,
        touch_conversation: conversation,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a friendly follow-up',
        scheduled_at: 25.hours.from_now
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:base]).to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
    end
  end

  describe 'auto-cancel defaults' do
    it 'defaults direct reminder creation to not auto-cancel on incoming replies' do
      reminder = create(:reminder)

      expect(reminder.auto_cancel_on_incoming).to be(false)
    end
  end

  describe 'status defaults' do
    it 'falls back to draft when routing is incomplete' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Draft me'
      )

      reminder.validate

      expect(reminder).to be_draft
    end

    it 'keeps agent touches pending when route and instructions are ready' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short and helpful follow-up'
      )

      reminder.validate

      expect(reminder).to be_pending
      expect(reminder).to be_ready_for_pending
    end
  end

  describe 'text mode normalization' do
    it 'detects Liquid syntax as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello {{contact.name}}', text_mode: :static)

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'detects field references as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello [Name](field://contact.name)')

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'ignores Liquid syntax inside code blocks for detection' do
      reminder = build(:reminder, body: 'Use `{{contact.name}}` as an example')

      reminder.validate

      expect(reminder.text_mode).to eq('static')
    end
  end

  describe 'repeat validation' do
    it 'rejects recurring relative touches' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil,
        repeat_mode: :weekly
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:repeat_mode]).to include('is only supported for absolute touches')
    end
  end
end
