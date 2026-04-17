require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappWebController', type: :request do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }

  describe 'POST /webhooks/whatsapp_web/:webhook_identifier' do
    it 'enqueues signed webhook payloads for async processing' do
      token = JWT.encode({ iss: 'evolution' }, channel.webhook_secret, 'HS256')

      expect do
        post "/webhooks/whatsapp_web/#{channel.webhook_identifier}",
             params: { event: 'connection.update', data: { state: 'open' } },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::WhatsappWeb::ProcessWebhookEventJob).with(
        channel.id,
        hash_including(
          'event' => 'connection.update',
          'whatsapp_web' => hash_including(
            'data' => hash_including('state' => 'open')
          )
        )
      ).on_queue('whatsappweb_inbound')

      expect(response).to have_http_status(:success)
    end

    it 'enqueues bootstrap batches for async processing too' do
      token = JWT.encode({ iss: 'evolution' }, channel.webhook_secret, 'HS256')

      expect do
        post "/webhooks/whatsapp_web/#{channel.webhook_identifier}",
             params: { event: 'messages.set', data: [{ key: { id: 'bootstrap-1' } }] },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::WhatsappWeb::ProcessWebhookEventJob).with(
        channel.id,
        hash_including(
          'event' => 'messages.set',
          'whatsapp_web' => hash_including(
            'data' => [hash_including('key' => hash_including('id' => 'bootstrap-1'))]
          )
        )
      ).on_queue('whatsappweb_inbound')

      expect(response).to have_http_status(:success)
    end

    it 'rejects unsigned webhook payloads' do
      post "/webhooks/whatsapp_web/#{channel.webhook_identifier}",
           params: { event: 'connection.update', data: { state: 'open' } },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns service unavailable when webhook enqueue fails due to redis outage' do
      token = JWT.encode({ iss: 'evolution' }, channel.webhook_secret, 'HS256')
      stub_const('RedisClient::CannotConnectError', Class.new(StandardError))

      allow(Channels::WhatsappWeb::ProcessWebhookEventJob).to receive(:perform_later)
        .and_raise(RedisClient::CannotConnectError.new('redis unavailable'))

      post "/webhooks/whatsapp_web/#{channel.webhook_identifier}",
           params: { event: 'connection.update', data: { state: 'open' } },
           headers: { 'Authorization' => "Bearer #{token}" },
           as: :json

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
