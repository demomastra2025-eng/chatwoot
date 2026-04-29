require 'rails_helper'

RSpec.describe 'Webhooks::WeixinController', type: :request do
  include ActiveJob::TestHelper

  GATEWAY_ISSUER = 'onelink-weixin-personal-gateway'.freeze

  let(:channel) { create(:channel_weixin) }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
  end

  def signed_headers(channel, body, jti: SecureRandom.uuid, exp: 5.minutes.from_now.to_i)
    token = JWT.encode(
      {
        iss: GATEWAY_ISSUER,
        channel_id: channel.id,
        body_sha256: Digest::SHA256.hexdigest(body),
        jti: jti,
        exp: exp
      },
      channel.webhook_secret,
      'HS256'
    )

    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
  end

  def post_signed_weixin(channel, payload, jti: SecureRandom.uuid, signed_body: nil)
    body = payload.to_json
    post "/webhooks/weixin/#{channel.webhook_identifier}",
         params: body,
         headers: signed_headers(channel, signed_body || body, jti: jti)
  end

  describe 'POST /webhooks/weixin/:webhook_identifier' do
    it 'enqueues signed webhook payloads for async processing' do
      payload = { event: 'message.created', message_id: 'msg-123', text: 'hello' }

      expect do
        post_signed_weixin(channel, payload)
      end.to have_enqueued_job(Channels::Weixin::ProcessWebhookEventJob)

      expect(response).to have_http_status(:success)
      expect(enqueued_jobs.last[:args]).to match(
        [channel.id, hash_including('event' => 'message.created', 'weixin' => hash_including('data' => hash_including('message_id' => 'msg-123')))]
      )
    end

    it 'unwraps gateway payloads that arrive under the top-level data key' do
      post_signed_weixin(
        channel,
        {
          event: 'message.created',
          data: {
            message_id: 'msg-456',
            sender_id: 'wxid_contact',
            chat_id: 'wxid_contact',
            text: '你好',
            context_token: 'context-token'
          }
        }
      )

      expect(response).to have_http_status(:success)
      expect(enqueued_jobs.last[:args].second).to match(
        hash_including(
          'event' => 'message.created',
          'weixin' => hash_including(
            'data' => hash_including(
              'message_id' => 'msg-456',
              'sender_id' => 'wxid_contact',
              'chat_id' => 'wxid_contact',
              'text' => '你好'
            )
          )
        )
      )
      expect(enqueued_jobs.last[:args].second.to_s).not_to include('context-token')
      expect(channel.reload.context_token_for('wxid_contact')).to eq('context-token')
    end

    it 'rejects unsigned webhook payloads' do
      post "/webhooks/weixin/#{channel.webhook_identifier}",
           params: { event: 'message.created', message_id: 'msg-123' },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects tokens signed for a different request body' do
      signed_body = { event: 'message.created', message_id: 'msg-original' }.to_json

      post_signed_weixin(
        channel,
        { event: 'message.created', message_id: 'msg-tampered' },
        signed_body: signed_body
      )

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects replayed webhook tokens' do
      jti = SecureRandom.uuid
      payload = { event: 'message.created', message_id: 'msg-replay' }

      post_signed_weixin(channel, payload, jti: jti)
      expect(response).to have_http_status(:success)

      expect do
        post_signed_weixin(channel, payload, jti: jti)
      end.not_to have_enqueued_job(Channels::Weixin::ProcessWebhookEventJob)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not consume replay token when enqueue fails transiently' do
      jti = SecureRandom.uuid
      payload = { event: 'message.created', message_id: 'msg-retry' }

      allow(Channels::Weixin::ProcessWebhookEventJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'redis down')

      post_signed_weixin(channel, payload, jti: jti)
      expect(response).to have_http_status(:service_unavailable)

      allow(Channels::Weixin::ProcessWebhookEventJob).to receive(:perform_later).and_call_original

      expect do
        post_signed_weixin(channel, payload, jti: jti)
      end.to have_enqueued_job(Channels::Weixin::ProcessWebhookEventJob)
      expect(response).to have_http_status(:success)
    end

    it 'applies runtime credential updates without serializing secrets into jobs' do
      channel.update_columns(ilink_token: nil, token_fingerprint: nil, provider_account_id: nil)

      payload = {
        event: 'runtime.updated',
        data: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          ilink_token: 'runtime-ilink-token',
          context_token: 'runtime-context-token',
          context_tokens: { wxid_contact: 'peer-context-token' },
          provider_account_id: 'wxid_bot',
          display_name: 'Weixin Bot'
        }
      }

      expect do
        post_signed_weixin(channel, payload)
      end.not_to have_enqueued_job(Channels::Weixin::ProcessWebhookEventJob)

      expect(response).to have_http_status(:success)
      channel.reload
      expect(channel.connection_state).to eq('connected')
      expect(channel.ilink_token).to eq('runtime-ilink-token')
      expect(channel.context_token).to eq('runtime-context-token')
      expect(channel.context_tokens_payload).to be_blank
    end
  end
end
