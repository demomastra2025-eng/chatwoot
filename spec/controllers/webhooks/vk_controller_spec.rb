require 'rails_helper'

RSpec.describe 'Webhooks::VkController', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { create(:channel_vk_community, group_id: 123_456, secret: 'vk-secret', confirmation_token: 'vk-confirm') }

  describe 'POST /webhooks/vk/:callback_id' do
    it 'returns 404 when callback_id does not match any channel' do
      post '/webhooks/vk/unknown-callback-id',
           params: { type: 'confirmation', group_id: 123_456 },
           as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'returns the confirmation token for confirmation events' do
      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'confirmation', group_id: channel.group_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('vk-confirm')
    end

    it 'rejects confirmation events with wrong group_id or explicit blank secret' do
      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'confirmation', group_id: 999_999 },
           as: :json
      expect(response).to have_http_status(:unauthorized)

      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'confirmation', group_id: channel.group_id, secret: '' },
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'enqueues message events for async processing while stripping secret from Redis payload' do
      expect do
        post "/webhooks/vk/#{channel.callback_id}",
             params: {
               type: 'message_new',
               group_id: channel.group_id,
               secret: channel.secret,
               object: { message: { id: 99, peer_id: 77, from_id: 77, text: 'hello' } }
             },
             as: :json
      end.to have_enqueued_job(Channels::VkCommunity::ProcessWebhookEventJob).with(
        channel.id,
        satisfy do |payload|
          !payload.key?('secret') &&
            payload['type'] == 'message_new' &&
            payload.dig('object', 'message', 'id') == 99 &&
            payload.dig('object', 'message', 'text') == 'hello'
        end
      )

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('ok')
    end

    it 'rejects invalid secrets with 401' do
      post "/webhooks/vk/#{channel.callback_id}",
           params: {
             type: 'message_new',
             group_id: channel.group_id,
             secret: 'bad-secret',
             object: { message: { id: 99 } }
           },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'fails closed with 401 when channel secret is blank instead of matching empty strings' do
      channel.update_column(:secret, '') # rubocop:disable Rails/SkipsModelValidations

      post "/webhooks/vk/#{channel.callback_id}",
           params: {
             type: 'message_new',
             group_id: channel.group_id,
             object: { message: { id: 99 } }
           },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns sanitized 422 on processing errors and 503 on transient queue errors without leaking exception details' do
      allow(Channels::VkCommunity::ProcessWebhookEventJob).to receive(:perform_later)
        .and_raise(StandardError, 'sensitive internal db host 10.0.0.5')

      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'message_new', group_id: channel.group_id, secret: channel.secret, object: { message: { id: 99 } } },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'Webhook processing failed')
      expect(response.body).not_to include('10.0.0.5')

      allow(Channels::VkCommunity::ProcessWebhookEventJob).to receive(:perform_later)
        .and_raise(ActiveJob::EnqueueError, 'redis://:secret_pass@10.0.0.9:6379')

      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'message_new', group_id: channel.group_id, secret: channel.secret, object: { message: { id: 99 } } },
           as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq('error' => 'Webhook processing failed')
      expect(response.body).not_to include('secret_pass')
    end
  end
end
