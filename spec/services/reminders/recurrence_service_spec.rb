require 'rails_helper'

RSpec.describe Reminders::RecurrenceService do
  describe '#schedule_next!' do
    it 'preserves the local wall-clock time across a daylight-saving transition' do
      zone = ActiveSupport::TimeZone['America/New_York']
      scheduled_at = zone.local(2026, 3, 7, 9, 0, 0)
      conversation = create(:conversation)
      reminder = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        scheduled_at: scheduled_at,
        timezone: 'America/New_York',
        repeat_mode: :daily,
        repeat_until_at: scheduled_at + 1.month,
        body: 'Daily local-time follow-up',
        metadata: { 'visible' => 'preserved' }
      )
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      reminder.mark_delivery_dispatched!(123)
      reminder.complete!

      next_touch = described_class.new(reminder: reminder).schedule_next!
      local_next = next_touch.scheduled_at.in_time_zone('America/New_York')

      expect(local_next.strftime('%Y-%m-%d %H:%M %z')).to eq('2026-03-08 09:00 -0400')
      expect(next_touch.timezone).to eq('America/New_York')
      expect(next_touch.metadata).to eq('visible' => 'preserved')
      expect(next_touch).not_to be_delivery_materialized
      expect(next_touch.processing_claim_token).to be_nil
    end

    it 're-resolves a stale target contact inbox against the current contact identity' do
      account = create(:account)
      contact = create(:contact, account: account, phone_number: '+77001232231')
      source_conversation = create(:conversation, account: account, contact: contact)
      target_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      stale_contact_inbox = create(
        :contact_inbox,
        contact: contact,
        inbox: target_channel.inbox,
        source_id: contact.phone_number.delete('+')
      )
      stale_conversation = create(
        :conversation,
        account: account,
        inbox: target_channel.inbox,
        contact: contact,
        contact_inbox: stale_contact_inbox
      )
      reminder = create(
        :reminder,
        account: account,
        remindable: source_conversation,
        conversation: source_conversation,
        target_inbox: target_channel.inbox,
        target_contact: contact,
        target_contact_inbox: stale_contact_inbox,
        target_conversation: stale_conversation,
        status: :completed,
        scheduled_at: 2.hours.ago,
        repeat_mode: :daily,
        repeat_until_at: 1.month.from_now
      )
      contact.update!(phone_number: '+77001232232')
      current_contact_inbox = create(
        :contact_inbox,
        contact: contact,
        inbox: target_channel.inbox,
        source_id: contact.phone_number.delete('+')
      )
      current_conversation = create(
        :conversation,
        account: account,
        inbox: target_channel.inbox,
        contact: contact,
        contact_inbox: current_contact_inbox
      )
      create(:message, account: account, inbox: target_channel.inbox, conversation: current_conversation, message_type: :incoming)

      next_touch = described_class.new(reminder: reminder).schedule_next!

      expect(next_touch.target_contact_inbox).to eq(current_contact_inbox)
      expect(next_touch.target_conversation).to eq(current_conversation)
    end
  end
end
