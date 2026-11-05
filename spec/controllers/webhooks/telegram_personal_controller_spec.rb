require 'rails_helper'

RSpec.describe 'Webhooks::TelegramPersonalController', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { create(:channel_telegram_personal) }

  describe 'POST /webhooks/telegram_personal/:webhook_identifier' do
    # Release scope explicitly defers provider edit metadata (9916e0f43e); both producers use the legacy reducer.
    context 'with message.updated callbacks' do
      let(:token) { JWT.encode({ iss: 'telegram-personal-gateway' }, channel.webhook_secret, 'HS256') }
      let(:data) { { message_id: '101', chat_id: '23', text: 'Corrected message' } }

      def send_update(attributes, signature: token)
        post "/webhooks/telegram_personal/#{channel.webhook_identifier}",
             params: { event: 'message.updated', data: attributes }, headers: { 'Authorization' => "Bearer #{signature}" }, as: :json
      end

      %w[private group album].each do |kind|
        it "queues and performs a signed legacy full #{kind} update without edit metadata" do
          chat_id = kind == 'private' ? '23' : '-10023'
          contact = create(:contact, account: channel.account)
          contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: chat_id)
          conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
          message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation,
                                     source_id: '101', content: 'Original message', content_attributes: { telegram_message_ids: %w[101 102] })
          attributes = data.merge(message_id: 101, chat_id: chat_id, peer_user_id: chat_id, sender_id: '23',
                                  chat_type: kind == 'private' ? 'private' : 'supergroup', caption: data[:text], outgoing_echo: true,
                                  message_created_at: '2026-11-01T00:00:00Z', attachments: [], location: nil, contact: nil,
                                  reply_to_message_id: nil, forwarded_from: nil, reactions: { total_count: 0, results: [] })
          attributes = attributes.merge(text: nil, message_id: 102, caption: 'Corrected message', grouped_id: '9001') if kind == 'album'

          expect { send_update(attributes) }.to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob).exactly(:once)
          expect(response).to have_http_status(:ok)
          queued = enqueued_jobs.find { |job| job[:job] == Channels::TelegramPersonal::ProcessWebhookEventJob }
          arguments = ActiveJob::Arguments.deserialize(queued[:args])
          expect(arguments.second.dig('telegram_personal', 'data')).to eq(attributes.deep_stringify_keys)
          Channels::TelegramPersonal::ProcessWebhookEventJob.perform_now(*arguments)

          expect(message.reload.content).to eq('Corrected message')
          expect(message.content_attributes['edited']).to be(true)
          expect(message.content_attributes['telegram_reactions']).to eq('total_count' => 0, 'results' => [])
          expect(message.content_attributes).not_to have_key('telegram_message_edited_at')
        end
      end

      it 'preserves new producer metadata in the queued callback without requiring it' do
        attributes = data.merge(message_edited_at: nil, message_edit_hidden: false)
        expect { send_update(attributes) }.to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob)

        expect(response).to have_http_status(:ok)
        arguments = ActiveJob::Arguments.deserialize(enqueued_jobs.last[:args])
        expect(arguments.second.dig('telegram_personal', 'data')).to eq(attributes.deep_stringify_keys)
      end

      it 'rejects a full update signed with another channel secret' do
        other_channel = create(:channel_telegram_personal)
        wrong_token = JWT.encode({ iss: 'telegram-personal-gateway' }, other_channel.webhook_secret, 'HS256')

        expect { send_update(data, signature: wrong_token) }.not_to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'keeps reaction-only callbacks compatible without text or caption' do
        attributes = { message_id: '101', chat_id: '23', reactions: { total_count: 0, results: [] } }
        expect { send_update(attributes) }.to have_enqueued_job(Channels::TelegramPersonal::ProcessWebhookEventJob)

        expect(response).to have_http_status(:ok)
      end
    end

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
