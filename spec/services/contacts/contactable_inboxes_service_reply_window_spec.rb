require 'rails_helper'

RSpec.describe Contacts::ContactableInboxesService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15551234567') }
  let(:whatsapp_channel) do
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
  end
  let(:whatsapp_inbox) { whatsapp_channel.inbox }

  before do
    stub_request(:get, /graph\.facebook\.com/)
  end

  describe 'official WhatsApp reply-window metadata' do
    it 'returns an open window from an earlier conversation of the same contact inbox' do
      contact_inbox = create(
        :contact_inbox,
        inbox: whatsapp_inbox,
        contact: contact,
        source_id: contact.phone_number.delete('+')
      )
      conversation = create(
        :conversation,
        account: account,
        inbox: whatsapp_inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      incoming_message = create(
        :message,
        account: account,
        inbox: whatsapp_inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 1.hour.ago
      )

      result = described_class.new(contact: contact).get.find { |entry| entry[:inbox] == whatsapp_inbox }

      expect(result[:source_id]).to eq(contact.phone_number.delete('+'))
      expect(result[:contact_inbox_id]).to eq(contact_inbox.id)
      expect(result[:active_conversation_id]).to eq(conversation.display_id)
      expect(result[:reply_window_open]).to be(true)
      expect(result[:allowed_content_kinds]).to contain_exactly('free_text', 'channel_template')
      expect(result[:reply_window_closes_at]).to be_within(1.second).of(incoming_message.created_at + 24.hours)
    end

    it 'returns a closed window when the contact has no prior inbox identity' do
      whatsapp_inbox
      result = described_class.new(contact: contact).get.find { |entry| entry[:inbox] == whatsapp_inbox }

      expect(result).to include(
        source_id: contact.phone_number.delete('+'),
        reply_window_open: false,
        reply_window_closes_at: nil,
        allowed_content_kinds: ['channel_template']
      )
    end

    it 'returns a closed window when the latest incoming message has expired' do
      contact_inbox = create(
        :contact_inbox,
        inbox: whatsapp_inbox,
        contact: contact,
        source_id: contact.phone_number.delete('+')
      )
      conversation = create(
        :conversation,
        account: account,
        inbox: whatsapp_inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      incoming_message = create(
        :message,
        account: account,
        inbox: whatsapp_inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 25.hours.ago
      )

      result = described_class.new(contact: contact).get.find { |entry| entry[:inbox] == whatsapp_inbox }

      expect(result[:reply_window_open]).to be(false)
      expect(result[:reply_window_closes_at]).to be_within(1.second).of(incoming_message.created_at + 24.hours)
      expect(result[:allowed_content_kinds]).to eq(['channel_template'])
    end

    it 'aggregates session state across identities of the same contact and inbox' do
      previous_contact_inbox = create(
        :contact_inbox,
        inbox: whatsapp_inbox,
        contact: contact,
        source_id: 'AB.providerbsuid123'
      )
      conversation = create(
        :conversation,
        account: account,
        inbox: whatsapp_inbox,
        contact: contact,
        contact_inbox: previous_contact_inbox
      )
      create(
        :message,
        account: account,
        inbox: whatsapp_inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 1.hour.ago
      )
      current_contact_inbox = create(
        :contact_inbox,
        inbox: whatsapp_inbox,
        contact: contact,
        source_id: contact.phone_number.delete('+')
      )

      result = described_class.new(contact: contact).get.find { |entry| entry[:inbox] == whatsapp_inbox }

      expect(result[:source_id]).to eq(contact.phone_number.delete('+'))
      expect(result[:contact_inbox_id]).to eq(current_contact_inbox.id)
      expect(result[:active_conversation_id]).to eq(conversation.display_id)
      expect(result[:reply_window_open]).to be(true)
      expect(result[:allowed_content_kinds]).to contain_exactly('free_text', 'channel_template')
    end

    it 'preloads polymorphic channels across multiple WhatsApp inboxes' do
      second_channel = create(
        :channel_whatsapp,
        account: account,
        sync_templates: false,
        validate_provider_config: false
      )
      whatsapp_inbox
      second_channel.inbox

      whatsapp_results = described_class.new(contact: contact).get.select do |entry|
        entry[:inbox].channel_type == 'Channel::Whatsapp'
      end

      expect(whatsapp_results.size).to eq(2)
      expect(whatsapp_results).to all(
        satisfy { |entry| entry[:inbox].association(:channel).loaded? }
      )
    end
  end
end
