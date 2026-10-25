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

    # The arguments of a job stay in Redis (and in the retry and dead sets and Sentry when it fails)
    it 'stores the session of a runtime snapshot at once and queues the snapshot without the session or the code hash' do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
           params: {
             event: 'runtime.updated',
             data: {
               connection_state: 'connected', lifecycle_state: 'code_sent', string_session: '1BVtsOK8Bu-webhook-session',
               runtime_state: { pending_phone_code_hash: 'webhook-code-hash', history_sync_state: 'running' }
             }
           },
           headers: { 'Authorization' => "Bearer #{token}" },
           as: :json

      expect(response).to have_http_status(:success)
      expect(channel.reload.string_session).to eq('1BVtsOK8Bu-webhook-session')
      args = enqueued_jobs.last[:args]
      expect(args.to_json).not_to include('1BVtsOK8Bu-webhook-session', 'webhook-code-hash')
      expect(args.second.dig('telegram_personal', 'data')).to include(
        'connection_state' => 'connected', 'runtime_state' => include('history_sync_state' => 'running')
      )

      perform_enqueued_jobs
      expect(channel.reload).to have_attributes(string_session: '1BVtsOK8Bu-webhook-session', lifecycle_state: 'code_sent')
      expect(channel.runtime_state).to include('history_sync_state' => 'running')
      expect(channel.runtime_state).not_to have_key('pending_phone_code_hash')
    end

    it 'keeps the stored session when a runtime snapshot comes without one' do
      channel.update!(string_session: 'stored-session')
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')

      post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
           params: { event: 'runtime.updated', data: { connection_state: 'disconnected', string_session: '' } },
           headers: { 'Authorization' => "Bearer #{token}" },
           as: :json

      expect(response).to have_http_status(:success)
      perform_enqueued_jobs
      expect(channel.reload.string_session).to eq('stored-session')
    end

    # Telegram's service account (777000) sends the login codes: their text never reaches Redis
    it 'leaves out a login code of the Telegram service account before it is queued and queues a person', :aggregate_failures do
      token = JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256')
      allow(Rails.logger).to receive(:info)
      login_code = { message_id: '901', chat_id: '777000', peer_user_id: '777000', chat_type: 'private', text: 'Login code: 51234' }

      %w[message.created message.imported].each do |event|
        expect do
          post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
               params: { event: event, data: login_code },
               headers: { 'Authorization' => "Bearer #{token}" },
               as: :json
        end.not_to have_enqueued_job
        expect(response).to have_http_status(:success)
      end

      expect(Rails.logger).to have_received(:info).with(a_string_including('Skipped message.created of a Telegram service account'))
      expect(Rails.logger).not_to have_received(:info).with(a_string_including('51234'))
      expect(channel.reload.last_synced_at).to be_present

      expect do
        post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
             params: { event: 'message.created', data: login_code.merge(chat_id: '23', peer_user_id: '23') },
             headers: { 'Authorization' => "Bearer #{token}" },
             as: :json
      end.to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob)
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
