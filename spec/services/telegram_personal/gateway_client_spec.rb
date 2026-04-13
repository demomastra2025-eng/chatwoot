require 'rails_helper'

RSpec.describe TelegramPersonal::GatewayClient do
  around do |example|
    with_modified_env(
      'TELEGRAM_PERSONAL_GATEWAY_URL' => 'http://telegram-personal-gateway.test',
      'TELEGRAM_PERSONAL_GATEWAY_TOKEN' => 'test-gateway-token'
    ) do
      example.run
    end
  end

  let(:channel) do
    instance_double(
      Channel::TelegramPersonal,
      id: 42,
      resolved_api_id: 24_110_447,
      resolved_api_hash: 'sharedhash',
      phone_number: '+77001234567',
      string_session: nil,
      callback_webhook_url: 'https://app.example.com/webhooks/telegram_personal/test',
      webhook_secret: 'secret',
      runtime_state_payload: {
        'history_sync_checkpoint' => {
          'version' => 1,
          'dialog_user_ids' => [],
          'next_dialog_index' => 0
        }
      }
    )
  end
  let(:client) { described_class.new(channel: channel) }

  describe '#sync_channel!' do
    it 'sends resolved API credentials so shared defaults can be used across inboxes' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { channel: { lifecycle_state: 'pending_auth' } }
      )

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42/sync")
        expect(JSON.parse(options[:body])).to include(
          'api_id' => 24_110_447,
          'api_hash' => 'sharedhash',
          'phone_number' => '+77001234567',
          'runtime_state' => hash_including(
            'history_sync_checkpoint' => hash_including(
              'version' => 1,
              'next_dialog_index' => 0
            )
          )
        )
      end.and_return(response)

      client.sync_channel!
    end
  end

  describe '#send_message!' do
    it 'falls back chat_id to contact_inbox source_id when conversation chat_id is missing' do
      contact_inbox = instance_double(ContactInbox, source_id: '77')
      conversation = instance_double(
        Conversation,
        contact_inbox: contact_inbox,
        additional_attributes: {}
      )
      message = instance_double(
        Message,
        conversation: conversation,
        outgoing_content: 'hello',
        content_attributes: {},
        attachments: []
      )

      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { message_id: '123' }
      )

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42/messages")
        expect(options[:headers]).to include(
          'Authorization' => 'Bearer test-gateway-token',
          'Content-Type' => 'application/json'
        )
        expect(JSON.parse(options[:body])).to eq(
          'recipient_id' => '77',
          'chat_id' => '77',
          'text' => 'hello',
          'reply_to_message_id' => nil,
          'attachments' => []
        )
        expect(options[:timeout]).to eq(60)
      end.and_return(response)

      client.send_message!(message)
    end

    it 'raises a gateway error when contact inbox source id is missing' do
      conversation = instance_double(
        Conversation,
        contact_inbox: nil,
        additional_attributes: {}
      )
      message = instance_double(
        Message,
        conversation: conversation,
        outgoing_content: 'hello',
        content_attributes: {},
        attachments: []
      )

      expect do
        client.send_message!(message)
      end.to raise_error(
        TelegramPersonal::GatewayClient::GatewayError,
        'Telegram Personal conversation is missing contact inbox source_id'
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
            runtime_state: { qr_login_url: 'tg://login?token=abc' }
          }
        }
      )

      expect(HTTParty).to receive(:post).with(
        "#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42/auth/request-qr",
        hash_including(headers: hash_including('Authorization'), body: '{}', timeout: 60)
      ).and_return(response)

      expect(client.request_qr_login!).to eq(
        {
          channel: {
            lifecycle_state: 'qr_ready',
            runtime_state: { qr_login_url: 'tg://login?token=abc' }
          }
        }.with_indifferent_access
      )
    end
  end

  describe '#history_sync!' do
    it 'sends advanced history sync controls to the gateway' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { channel: { lifecycle_state: 'connected' } }
      )

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42/history-sync")
        expect(JSON.parse(options[:body])).to eq(
          'force' => false,
          'reset_cursor' => true,
          'include_contacts' => true
        )
      end.and_return(response)

      client.history_sync!(force: false, reset_cursor: true, include_contacts: true)
    end
  end

  describe '#contacts_sync!' do
    it 'sends a contacts sync request to the gateway' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { channel: { lifecycle_state: 'connected' } }
      )

      expect(HTTParty).to receive(:post) do |url, options|
        expect(url).to eq("#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42/contacts-sync")
        expect(JSON.parse(options[:body])).to eq(
          'force' => false
        )
      end.and_return(response)

      client.contacts_sync!(force: false)
    end
  end

  describe '#teardown_channel!' do
    it 'issues a delete request to the channel runtime endpoint' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { ok: true }
      )

      expect(HTTParty).to receive(:delete).with(
        "#{ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')}/internal/channels/42",
        hash_including(headers: hash_including('Authorization'))
      ).and_return(response)

      expect(client.teardown_channel!).to eq({ ok: true }.with_indifferent_access)
    end
  end
end
