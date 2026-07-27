require 'rails_helper'

RSpec.describe Reminders::ConversationResolver do
  describe '#perform' do
    it 'raises a non-retryable error when the target cannot be routed to the inbox' do
      inbox = instance_double(Inbox)
      contact = instance_double(Contact)
      reminder = instance_double(
        Reminder,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: nil,
        target_inbox: inbox,
        target_contact: contact
      )
      resolver = instance_double(Outbound::ContactInboxResolver, perform: nil)

      allow(Outbound::ContactInboxResolver).to receive(:new).with(inbox: inbox, contact: contact).and_return(resolver)

      expect { described_class.new(reminder: reminder).perform }
        .to raise_error(Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox')
    end

    it 'preserves Telegram transport attributes when replacing a resolved conversation' do
      account = create(:account)
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
      inactive_conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        additional_attributes: { 'chat_id' => 111_111_111 }
      )
      inactive_conversation.update_columns(created_at: 30.minutes.ago, last_activity_at: 2.hours.ago) # rubocop:disable Rails/SkipsModelValidations
      resolved_conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        additional_attributes: {
          'chat_id' => 987_654_321,
          'business_connection_id' => 'business-1'
        }
      )
      resolved_conversation.update_columns(created_at: 2.days.ago, last_activity_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      reminder = instance_double(
        Reminder,
        account_id: account.id,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: contact_inbox,
        target_inbox: inbox,
        target_contact: contact,
        metadata: {},
        body: 'Follow up'
      )

      conversation = described_class.new(reminder: reminder).perform

      expect(conversation).not_to eq(resolved_conversation)
      expect(conversation.additional_attributes).to include(
        'chat_id' => 987_654_321,
        'business_connection_id' => 'business-1'
      )
    end

    it 'falls back to the Telegram contact inbox source id' do
      account = create(:account)
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
      reminder = instance_double(
        Reminder,
        account_id: account.id,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: contact_inbox,
        target_inbox: inbox,
        target_contact: contact,
        metadata: {},
        body: 'Follow up'
      )

      conversation = described_class.new(reminder: reminder).perform

      expect(conversation.additional_attributes['chat_id']).to eq('123456789')
    end

    it 'falls back when the latest Telegram conversation has a blank chat id' do
      account = create(:account)
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        additional_attributes: { 'chat_id' => '' }
      )
      reminder = instance_double(
        Reminder,
        account_id: account.id,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: contact_inbox,
        target_inbox: inbox,
        target_contact: contact,
        metadata: {},
        body: 'Follow up'
      )

      conversation = described_class.new(reminder: reminder).perform

      expect(conversation.additional_attributes['chat_id']).to eq('123456789')
    end
  end
end
