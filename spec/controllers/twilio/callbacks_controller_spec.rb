require 'rails_helper'

RSpec.describe 'Twilio::CallbacksController', type: :request do
  include Rails.application.routes.url_helpers

  describe 'POST /twilio/callback' do
    let!(:channel) do
      create(:channel_twilio_sms, :with_phone_number, account_sid: params['AccountSid'], auth_token: 'twilio-auth-token', phone_number: params['To'])
    end
    let(:params) do
      {
        'From' => '+123****7890',
        'To' => '+0987654321',
        'Body' => 'Test message',
        'AccountSid' => 'AC123',
        'SmsSid' => 'SM123'
      }
    end
    let(:signature) do
      Twilio::Security::RequestValidator.new(channel.auth_token).build_signature_for(twilio_callback_index_url, params)
    end

    it 'enqueues the Twilio events job' do
      expect do
        post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => signature }
      end.to have_enqueued_job(Webhooks::TwilioEventsJob).with(params)
    end

    it 'returns no content status' do
      post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => signature }
      expect(response).to have_http_status(:no_content)
    end

    it 'validates the full Twilio payload before enqueueing only permitted params' do
      request_params = params.merge('NewTwilioParam' => 'signed but not enqueued')
      request_signature = Twilio::Security::RequestValidator.new(channel.auth_token).build_signature_for(twilio_callback_index_url, request_params)

      expect do
        post twilio_callback_index_url, params: request_params, headers: { 'X-Twilio-Signature' => request_signature }
      end.to have_enqueued_job(Webhooks::TwilioEventsJob).with(params)
    end

    it 'accepts a signature generated for the configured public frontend URL' do
      public_callback_url = 'https://crm.example.com/twilio/callback'
      public_signature = Twilio::Security::RequestValidator.new(channel.auth_token).build_signature_for(public_callback_url, params)

      with_modified_env FRONTEND_URL: 'https://crm.example.com' do
        expect do
          post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => public_signature }
        end.to have_enqueued_job(Webhooks::TwilioEventsJob).with(params)
      end
    end

    it 'validates API-key channels with the configured account auth token' do
      channel.update!(api_key_sid: 'SK123', auth_token: 'twilio-api-key-secret')
      account_auth_token = 'twilio-account-auth-token'
      api_key_signature = Twilio::Security::RequestValidator.new(account_auth_token).build_signature_for(twilio_callback_index_url, params)

      with_modified_env TWILIO_ACCOUNT_AUTH_TOKEN: account_auth_token do
        expect do
          post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => api_key_signature }
        end.to have_enqueued_job(Webhooks::TwilioEventsJob).with(params)
      end
    end

    it 'rejects API-key channels when no account auth token is configured' do
      channel.update!(api_key_sid: 'SK123', auth_token: 'twilio-api-key-secret')
      api_key_signature = Twilio::Security::RequestValidator.new(channel.auth_token).build_signature_for(twilio_callback_index_url, params)

      with_modified_env TWILIO_ACCOUNT_AUTH_TOKEN: nil, TWILIO_AUTH_TOKEN: nil do
        expect do
          post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => api_key_signature }
        end.not_to have_enqueued_job(Webhooks::TwilioEventsJob)
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an invalid signature without enqueueing the job' do
      expect do
        post twilio_callback_index_url, params: params, headers: { 'X-Twilio-Signature' => 'invalid' }
      end.not_to have_enqueued_job(Webhooks::TwilioEventsJob)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a missing signature without enqueueing the job' do
      expect do
        post twilio_callback_index_url, params: params
      end.not_to have_enqueued_job(Webhooks::TwilioEventsJob)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
