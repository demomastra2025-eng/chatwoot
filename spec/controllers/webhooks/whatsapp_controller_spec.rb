require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappController', type: :request do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:client_secret) { 'test-whatsapp-secret' }
  let(:body) { { content: 'hello' }.to_json }

  def signature_for(payload, secret = client_secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_whatsapp_webhook(path, payload, signature: signature_for(payload), env: { WHATSAPP_APP_SECRET: client_secret })
    with_modified_env env do
      post path,
           params: payload,
           headers: { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => signature }
    end
  end

  def post_unsigned_whatsapp_webhook(path, payload, env: { WHATSAPP_APP_SECRET: client_secret })
    with_modified_env env do
      post path,
           params: payload,
           headers: { 'CONTENT_TYPE' => 'application/json' }
    end
  end

  before do
    InstallationConfig.where(name: 'WHATSAPP_APP_SECRET').delete_all
    GlobalConfig.clear_cache
  end

  describe 'GET /webhooks/verify' do
    it 'returns 401 when valid params are not present' do
      get "/webhooks/whatsapp/#{channel.phone_number}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 when invalid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => 'invalid' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns challenge when valid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => channel.provider_config['webhook_verify_token'] }
      expect(response.body).to include '123456'
    end
  end

  describe 'POST /webhooks/whatsapp/{:phone_number}' do
    it 'calls the whatsapp events job with the params for a valid global app signature' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body)

      expect(response).to have_http_status(:success)
    end

    it 'accepts webhook payloads signed with the channel app secret' do
      channel_secret = '[REDACTED]'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret))

      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        channel_body,
        signature: signature_for(channel_body, channel_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'skips signature validation for 360dialog channels' do
      dialog_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)

      expect(response).to have_http_status(:success)
    end

    it 'keeps legacy manual whatsapp cloud channels working when no app secret is configured' do
      channel.update!(provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source'))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Rails.logger).to receive(:warn)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", channel_body, env: {})

      expect(response).to have_http_status(:success)
      expect(Rails.logger).to have_received(:warn).with(/skipping HMAC validation/)
    end

    it 'keeps URL-resolved legacy manual whatsapp cloud channels working when no app secret is configured' do
      channel.update!(provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source'))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Rails.logger).to receive(:warn)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", body, env: {})

      expect(response).to have_http_status(:success)
      expect(Rails.logger).to have_received(:warn).with(/skipping HMAC validation/)
    end

    it 'rejects embedded-signup whatsapp cloud channels when no app secret is configured' do
      channel.update!(
        provider_config: channel.provider_config
                                .merge('source' => 'embedded_signup')
                                .except('app_secret', 'app_secret_key', 'api_secret', 'client_secret')
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", body, env: {})

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature is missing and verification is required' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook('/webhooks/whatsapp/15550000000', body)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature is invalid' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body, signature: 'sha256=invalid-signature')

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature uses an unsupported prefix' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body, signature: 'sha1=invalid-signature')

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    context 'when phone number is in inactive list' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return('+15550000001,+15550000002')
      end

      it 'returns service unavailable for inactive phone number in URL params after signature verification' do
        allow(Rails.logger).to receive(:warn)
        expect(Rails.logger).to receive(:warn).with('Rejected webhook for inactive WhatsApp number: +15550000001')

        post_whatsapp_webhook('/webhooks/whatsapp/+15550000001', body)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Inactive WhatsApp number')
      end
    end

    context 'when INACTIVE_WHATSAPP_NUMBERS config is not set' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return(nil)
      end

      it 'processes the webhook normally with a valid signature' do
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
        expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

        post_whatsapp_webhook('/webhooks/whatsapp/+15550000001', body)
        expect(response).to have_http_status(:success)
      end
    end
  end
end
