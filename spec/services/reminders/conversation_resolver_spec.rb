require 'rails_helper'

RSpec.describe Reminders::ConversationResolver do
  it 'does not execute a persisted route after the WhatsApp contact identity changes' do
    account = create(:account)
    contact = create(:contact, account: account, phone_number: '+77001232231')
    channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
    stale_contact_inbox = create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: contact.phone_number.delete('+')
    )
    stale_conversation = create(
      :conversation,
      account: account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: stale_contact_inbox
    )
    create(:message, account: account, inbox: channel.inbox, conversation: stale_conversation, message_type: :incoming)
    reminder = create(
      :reminder,
      account: account,
      conversation: stale_conversation,
      remindable: stale_conversation,
      target_inbox: channel.inbox,
      target_contact: contact,
      target_contact_inbox: stale_contact_inbox,
      target_conversation: stale_conversation,
      status: :pending
    )
    contact.update!(phone_number: '+77001232232')
    current_contact_inbox = create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: contact.phone_number.delete('+')
    )
    current_conversation = create(
      :conversation,
      account: account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: current_contact_inbox
    )

    resolved_conversation = described_class.new(reminder: reminder).perform

    expect(resolved_conversation).to eq(current_conversation)
  end

  describe '#perform' do
    it 'does not return an open source conversation from another inbox' do
      account = create(:account)
      source_inbox = create(:inbox, account: account)
      target_inbox = create(:inbox, account: account)
      contact = create(:contact, account: account)
      source_contact_inbox = create(:contact_inbox, contact: contact, inbox: source_inbox)
      target_contact_inbox = create(:contact_inbox, contact: contact, inbox: target_inbox)
      source_conversation = create(
        :conversation,
        account: account,
        inbox: source_inbox,
        contact: contact,
        contact_inbox: source_contact_inbox,
        status: :open
      )
      reminder = build(
        :reminder,
        account: account,
        conversation: source_conversation,
        remindable: source_conversation,
        target_inbox: target_inbox,
        target_contact: contact,
        target_contact_inbox: target_contact_inbox,
        target_conversation: nil
      )

      resolved = described_class.new(reminder: reminder).perform

      expect(resolved).not_to eq(source_conversation)
      expect(resolved).to have_attributes(
        account_id: account.id,
        inbox_id: target_inbox.id,
        contact_id: contact.id,
        contact_inbox_id: target_contact_inbox.id
      )
    end

    it 'raises a non-retryable error when the target cannot be routed to the inbox' do
      inbox = instance_double(Inbox, channel_type: 'Channel::Api')
      contact = instance_double(Contact)
      reminder = instance_double(
        Reminder,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: nil,
        target_inbox: inbox,
        target_contact: contact
      )
      identity_resolver = instance_double(Campaigns::TargetResolver, resolve: nil)
      resolver = instance_double(Outbound::ContactInboxResolver, perform: nil)

      allow(Campaigns::TargetResolver).to receive(:new).with(inbox: inbox, contact: contact).and_return(identity_resolver)
      allow(Outbound::ContactInboxResolver).to receive(:new)
        .with(inbox: inbox, contact: contact, source_id: nil)
        .and_return(resolver)

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
