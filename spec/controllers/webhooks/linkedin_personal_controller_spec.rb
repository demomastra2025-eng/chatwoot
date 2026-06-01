require 'rails_helper'

RSpec.describe 'Webhooks::LinkedinPersonalController', type: :request do
  let(:channel) { create(:channel_linkedin_personal) }

  def jwt_for(event)
    JWT.encode(
      { iss: 'linkedin-personal-gateway', channel_id: channel.id, event: event, exp: 5.minutes.from_now.to_i },
      channel.webhook_secret,
      'HS256'
    )
  end

  describe 'POST /webhooks/linkedin_personal/:webhook_identifier' do
    it 'enqueues a signed realtime event' do
      expect(Channels::LinkedinPersonal::ProcessWebhookEventJob).to receive(:perform_later).with(
        channel.id,
        hash_including(
          'event' => 'message.created',
          'linkedin_personal' => include(
            'data' => include('message_id' => 'urn:li:msg:1')
          )
        )
      )

      post "/webhooks/linkedin_personal/#{channel.webhook_identifier}",
           params: { event: 'message.created', data: { message_id: 'urn:li:msg:1' } },
           headers: { 'Authorization' => "Bearer #{jwt_for('message.created')}" },
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'rejects unsigned events' do
      post "/webhooks/linkedin_personal/#{channel.webhook_identifier}",
           params: { event: 'message.created', data: { message_id: 'urn:li:msg:1' } },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
