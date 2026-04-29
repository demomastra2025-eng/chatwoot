require 'rails_helper'

RSpec.describe Weixin::SendOnWeixinService do
  describe '#perform' do
    it 'marks outgoing messages as sent with the provider message id' do
      channel = create(:channel_weixin)
      inbox = channel.inbox
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'wxid_contact')
      conversation = create(:conversation, inbox: inbox, contact: contact, contact_inbox: contact_inbox, account: channel.account)
      message = create(:message, message_type: :outgoing, inbox: inbox, conversation: conversation, account: channel.account, content: 'hello')

      allow(Weixin::GatewayClient).to receive(:new).with(channel: channel).and_return(
        instance_double(Weixin::GatewayClient, send_message!: { message_id: 'out-msg-1' })
      )

      described_class.new(message: message).perform
      message.reload

      expect(message.source_id).to eq('out-msg-1')
      expect(message.status).to eq('sent')
    end

    it 'marks outgoing messages as failed when gateway delivery fails' do
      channel = create(:channel_weixin)
      inbox = channel.inbox
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'wxid_contact')
      conversation = create(:conversation, inbox: inbox, contact: contact, contact_inbox: contact_inbox, account: channel.account)
      message = create(:message, message_type: :outgoing, inbox: inbox, conversation: conversation, account: channel.account, content: 'hello')

      gateway = instance_double(Weixin::GatewayClient)
      allow(gateway).to receive(:send_message!).and_raise(Weixin::GatewayClient::GatewayError, 'provider unavailable')
      allow(Weixin::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway)

      described_class.new(message: message).perform
      message.reload

      expect(message.status).to eq('failed')
      expect(message.external_error).to eq('provider unavailable')
    end
  end
end
