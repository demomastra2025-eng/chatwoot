require 'rails_helper'

RSpec.describe 'Webhooks::VkController', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { create(:channel_vk_community, group_id: 123_456, secret: 'vk-secret', confirmation_token: 'vk-confirm') }

  describe 'POST /webhooks/vk/:callback_id' do
    it 'returns the confirmation token for confirmation events' do
      post "/webhooks/vk/#{channel.callback_id}",
           params: { type: 'confirmation', group_id: channel.group_id },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('vk-confirm')
    end

    it 'enqueues message events for async processing' do
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
        hash_including(
          'type' => 'message_new',
          'object' => hash_including(
            'message' => hash_including('id' => 99, 'text' => 'hello')
          )
        )
      )

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('ok')
    end

    it 'rejects invalid secrets' do
      post "/webhooks/vk/#{channel.callback_id}",
           params: {
             type: 'message_new',
             group_id: channel.group_id,
             secret: 'bad-secret',
             object: { message: { id: 99 } }
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
