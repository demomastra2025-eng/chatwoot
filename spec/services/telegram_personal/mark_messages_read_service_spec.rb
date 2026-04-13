require 'rails_helper'

RSpec.describe TelegramPersonal::MarkMessagesReadService do
  describe '#perform' do
    it 'marks unread incoming telegram personal messages as read in the provider' do
      channel = create(:channel_telegram_personal)
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: { 'chat_id' => '23' }
      )
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :incoming,
        source_id: '101',
        content_attributes: { 'telegram_message_ids' => %w[101 102] }
      )
      gateway_client = instance_double(TelegramPersonal::GatewayClient, mark_read!: true)

      allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)

      result = described_class.new(conversation: conversation, messages: [message]).perform

      expect(result).to be(true)
      expect(gateway_client).to have_received(:mark_read!).with(
        recipient_id: '23',
        chat_id: '23',
        max_id: '102'
      )
    end
  end
end
