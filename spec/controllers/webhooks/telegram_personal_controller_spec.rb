require 'rails_helper'

RSpec.describe 'Webhooks::TelegramPersonalController', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { create(:channel_telegram_personal) }

  describe 'POST /webhooks/telegram_personal/:webhook_identifier' do
    it 'enqueues signed webhook payloads for async processing' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      expect do
        post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
             params: { event: 'message.created', message_id: '123', text: 'hello' },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob)
        .on_queue('telegram_personal_inbound')

      expect(response).to have_http_status(:success)

      enqueued_job = enqueued_jobs.last
      expect(enqueued_job[:args].first).to eq(channel.id)
      expect(enqueued_job[:args].second).to include(
        'event' => 'message.created',
        'telegram_personal' => include(
          'data' => include('message_id' => '123', 'text' => 'hello')
        )
      )
    end

    it 'unwraps gateway payloads that arrive under the top-level data key' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
           params: {
             event: 'message.created',
             data: {
               message_id: '16025',
               peer_user_id: '134527512',
               chat_id: '134527512',
               text: 'Салам'
             }
           },
           headers: { 'Authorization' => "Bearer #{token}" },
           as: :json

      expect(response).to have_http_status(:success)

      enqueued_job = enqueued_jobs.last
      expect(enqueued_job[:args].second).to include(
        'event' => 'message.created',
        'telegram_personal' => include(
          'data' => include(
            'message_id' => '16025',
            'peer_user_id' => '134527512',
            'chat_id' => '134527512',
            'text' => 'Салам'
          )
        )
      )
    end

    it 'routes imported history payloads to the dedicated history queue job' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      expect do
        post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
             params: { event: 'message.imported', message_id: '124', text: 'history hello', imported_history: true },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::TelegramPersonal::ProcessHistoryWebhookEventJob)

      expect(response).to have_http_status(:success)
    end

    it 'routes imported contact payloads to the dedicated history queue job' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      expect do
        post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
             params: { event: 'contact.imported', peer_user_id: '23', username: 'sojan' },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::TelegramPersonal::ProcessHistoryWebhookEventJob)

      expect(response).to have_http_status(:success)
    end

    it 'rejects unsigned webhook payloads' do
      post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
           params: { event: 'message.created', message_id: '123' },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns service unavailable when enqueue fails due to redis outage' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')
      stub_const('RedisClient::CannotConnectError', Class.new(StandardError))

      allow(Channels::TelegramPersonal::ProcessWebhookEventJob).to receive(:perform_later)
        .and_raise(RedisClient::CannotConnectError.new('redis unavailable'))

      post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
           params: { event: 'runtime.updated', connection_state: 'connected' },
           headers: { 'Authorization' => "Bearer #{token}" },
           as: :json

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
