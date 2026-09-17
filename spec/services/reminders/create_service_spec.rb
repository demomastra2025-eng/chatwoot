require 'rails_helper'

RSpec.describe Reminders::CreateService do
  describe '#perform' do
    it 'replaces a stale target contact inbox after the contact identity changes' do
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

      reminder = described_class.new(
        account: account,
        remindable: source_conversation,
        attributes: {
          body: 'Use the current contact identity',
          scheduled_at: 1.hour.from_now,
          target_inbox_id: target_channel.inbox.id,
          target_contact_inbox_id: stale_contact_inbox.id
        }
      ).perform

      expect(reminder.target_contact_inbox).to eq(current_contact_inbox)
      expect(reminder.target_conversation).to eq(current_conversation)
    end

    it 'rolls back a contact inbox created during route resolution when the reminder is invalid' do
      account = create(:account)
      contact = create(:contact, account: account, phone_number: '+77001232233')
      source_inbox = create(:inbox, account: account)
      source_contact_inbox = create(:contact_inbox, contact: contact, inbox: source_inbox)
      conversation = create(
        :conversation,
        account: account,
        inbox: source_inbox,
        contact: contact,
        contact_inbox: source_contact_inbox
      )
      target_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)

      expect do
        described_class.new(
          account: account,
          remindable: conversation,
          attributes: {
            body: 'Invalid cross-inbox final touch',
            scheduled_at: 1.hour.from_now,
            target_inbox_id: target_channel.inbox.id,
            post_delivery_action: 'resolve_conversation'
          }
        ).perform
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(contact.contact_inboxes.where(inbox: target_channel.inbox)).to be_empty
      expect(account.reminders.exists?).to be(false)
    end
  end
end
