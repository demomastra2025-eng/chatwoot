require 'rails_helper'

RSpec.describe 'Webhooks::SmsController', type: :request do
  let!(:sms_channel) do
    create(
      :channel_sms,
      phone_number: '+12345678901',
      provider_config: {
        'account_id' => 'acc-1',
        'application_id' => 'app-1',
        'api_key' => 'bw-api-user',
        'api_secret' => 'bw-api-secret'
      }
    )
  end

  def basic_auth_header(user, pass)
    { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass) }
  end

  describe 'POST /webhooks/sms/:phone_number' do
    it 'rejects unauthenticated requests with 401 and does not enqueue job' do
      expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects requests for unknown phone numbers with 401' do
      expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)

      post '/webhooks/sms/+19999999999',
           params: [{ type: 'message-received', to: '+19999999999' }].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects wrong Basic Auth credentials with 401' do
      expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: basic_auth_header('bw-api-user', 'wrong-secret').merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'enqueues SmsEventsJob when authenticated with Bandwidth Basic Auth credentials' do
      expect(Webhooks::SmsEventsJob).to receive(:perform_later).with(
        hash_including('type' => 'message-received', 'to' => sms_channel.phone_number)
      )

      post '/webhooks/sms/12345678901',
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:ok)
    end

    it 'accepts outbound Bandwidth delivery receipts where to is the customer number and message.owner is the channel' do
      expect(Webhooks::SmsEventsJob).to receive(:perform_later).with(
        hash_including('type' => 'message-delivered', 'to' => sms_channel.phone_number)
      )

      delivery_payload = [{
        type: 'message-delivered',
        to: ['+19195554321'],
        message: { id: 'msg-1', direction: 'out', owner: sms_channel.phone_number, to: ['+19195554321'] }
      }]

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: delivery_payload.to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:ok)
    end

    it 'enforces dedicated webhook_username/webhook_password over api_key/api_secret when configured' do
      sms_channel.update!(
        provider_config: sms_channel.provider_config.merge(
          'webhook_username' => 'cb-user',
          'webhook_password' => 'cb-pass'
        )
      )

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:unauthorized)

      expect(Webhooks::SmsEventsJob).to receive(:perform_later)
      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: basic_auth_header('cb-user', 'cb-pass').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:ok)
    end

    it 'accepts per-channel X-Sms-Webhook-Secret and blocks global SMS_WEBHOOK_SECRET from bypassing per-channel Basic Auth' do
      with_modified_env SMS_WEBHOOK_SECRET: 'global-fallback-secret' do
        post "/webhooks/sms/#{sms_channel.phone_number}",
             params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
             headers: { 'CONTENT_TYPE' => 'application/json', 'X-Sms-Webhook-Secret' => 'global-fallback-secret' }
        expect(response).to have_http_status(:unauthorized)
      end

      sms_channel.update!(provider_config: sms_channel.provider_config.merge('webhook_secret' => 'shared-sms-secret'))
      expect(Webhooks::SmsEventsJob).to receive(:perform_later)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: sms_channel.phone_number }].to_json,
           headers: { 'CONTENT_TYPE' => 'application/json', 'X-Sms-Webhook-Secret' => 'shared-sms-secret' }

      expect(response).to have_http_status(:ok)
    end

    it 'rejects cross-channel payload spoofing via inbound to or message.owner' do
      other_channel = create(:channel_sms, phone_number: '+12223334444')
      expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-received', to: other_channel.phone_number }].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:unauthorized)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [{ type: 'message-delivered', message: { direction: 'out', owner: other_channel.phone_number } }].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'handles empty ping payloads without enqueueing nil and rejects malformed non-object arrays with 422' do
      expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: [].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:ok)

      post "/webhooks/sms/#{sms_channel.phone_number}",
           params: ['ping'].to_json,
           headers: basic_auth_header('bw-api-user', 'bw-api-secret').merge('CONTENT_TYPE' => 'application/json')
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
