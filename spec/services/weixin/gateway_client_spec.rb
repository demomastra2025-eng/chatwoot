require 'rails_helper'

RSpec.describe Weixin::GatewayClient do
  around do |example|
    with_modified_env(
      'WEIXIN_GATEWAY_URL' => 'http://weixin-gateway.test',
      'WEIXIN_GATEWAY_TOKEN' => 'test-gateway-token'
    ) do
      example.run
    end
  end

  let(:channel) do
    instance_double(
      Channel::Weixin,
      id: 42,
      resolved_ilink_token: 'ilink-token',
      provider_account_id: 'wxid_bot',
      display_name: 'Weixin Bot',
      context_token: 'context-token',
      context_tokens_payload: { 'wxid_contact' => 'conversation-context' },
      callback_webhook_url: 'https://app.example.com/webhooks/weixin/test',
      webhook_secret: 'secret',
      runtime_state_payload: { 'poller_state' => 'idle', 'last_update_id' => nil }
    )
  end
  let(:client) { described_class.new(channel: channel) }

  describe '#sync_channel!' do
    it 'sends native channel credentials and callback boundary to the gateway' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { channel: { lifecycle_state: 'pending_auth' } }
      )

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('WEIXIN_GATEWAY_URL')}/internal/channels/42/sync")
        expect(options[:headers]).to include(
          'Authorization' => 'Bearer test-gateway-token',
          'Content-Type' => 'application/json'
        )
        expect(JSON.parse(options[:body])).to include(
          'ilink_token' => 'ilink-token',
          'provider_account_id' => 'wxid_bot',
          'display_name' => 'Weixin Bot',
          'context_token' => 'context-token',
          'context_tokens' => { 'wxid_contact' => 'conversation-context' },
          'callback_url' => 'https://app.example.com/webhooks/weixin/test',
          'webhook_secret' => 'secret',
          'runtime_state' => hash_including('poller_state' => 'idle')
        )
      end.and_return(response)

      client.sync_channel!
    end

    it 'raises a gateway error when the gateway URL is not configured' do
      with_modified_env('WEIXIN_GATEWAY_URL' => nil) do
        expect { client.sync_channel! }.to raise_error(
          Weixin::GatewayClient::GatewayError,
          /WEIXIN_GATEWAY_URL/
        )
      end
    end

    it 'wraps gateway transport failures without leaking a raw exception' do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect { client.sync_channel! }.to raise_error(
        Weixin::GatewayClient::GatewayError,
        /Weixin gateway unavailable/
      )
    end
  end

  describe '#request_qr_login!' do
    it 'issues a post request to the qr login endpoint' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: {
          channel: {
            lifecycle_state: 'qr_ready',
            runtime_state: { qr_login_url: 'https://login.example/qr' }
          }
        }
      )

      expect(HTTParty).to receive(:post).with(
        "#{ENV.fetch('WEIXIN_GATEWAY_URL')}/internal/channels/42/auth/request-qr",
        hash_including(headers: hash_including('Authorization'), body: '{}', timeout: 60)
      ).and_return(response)

      expect(client.request_qr_login!).to eq(
        {
          channel: {
            lifecycle_state: 'qr_ready',
            runtime_state: { qr_login_url: 'https://login.example/qr' }
          }
        }.with_indifferent_access
      )
    end
  end

  describe '#send_message!' do
    it 'sends recipient, text, context token and attachments to the gateway' do
      contact_inbox = instance_double(ContactInbox, source_id: 'wxid_contact')
      allow(channel).to receive(:context_token_for).with('wxid_contact').and_return('conversation-context')
      conversation = instance_double(
        Conversation,
        contact_inbox: contact_inbox,
        additional_attributes: {
          'weixin_chat_id' => 'chat-room-1'
        }
      )
      message = instance_double(
        Message,
        conversation: conversation,
        outgoing_content: 'hello',
        content_attributes: { 'in_reply_to_external_id' => 'msg-1' },
        attachments: []
      )
      response = instance_double(HTTParty::Response, success?: true, parsed_response: { message_id: 'out-1' })

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('WEIXIN_GATEWAY_URL')}/internal/channels/42/messages")
        expect(JSON.parse(options[:body])).to eq(
          'recipient_id' => 'wxid_contact',
          'chat_id' => 'chat-room-1',
          'text' => 'hello',
          'context_token' => 'conversation-context',
          'reply_to_message_id' => 'msg-1',
          'attachments' => []
        )
      end.and_return(response)

      client.send_message!(message)
    end

    it 'raises a gateway error when contact inbox source id is missing' do
      conversation = instance_double(Conversation, contact_inbox: nil, additional_attributes: {})
      message = instance_double(Message, conversation: conversation, outgoing_content: 'hello', content_attributes: {}, attachments: [])

      expect { client.send_message!(message) }.to raise_error(
        Weixin::GatewayClient::GatewayError,
        'Weixin conversation is missing contact inbox source_id'
      )
    end
  end
end
