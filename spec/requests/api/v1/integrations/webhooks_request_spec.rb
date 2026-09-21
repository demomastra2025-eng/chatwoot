require 'rails_helper'

RSpec.describe 'Api::V1::Integrations::Webhooks' do
  describe 'POST /api/v1/integrations/webhooks' do
    let(:signing_secret) { 'slack-signing-secret' }
    let(:timestamp) { Time.current.to_i.to_s }
    let(:payload) { { type: 'url_verification', challenge: 'challenge' }.to_json }
    let(:signature) do
      digest = OpenSSL::HMAC.hexdigest('SHA256', signing_secret, "v0:#{timestamp}:#{payload}")
      "v0=#{digest}"
    end
    let(:headers) do
      {
        'CONTENT_TYPE' => 'application/json',
        'X-Slack-Request-Timestamp' => timestamp,
        'X-Slack-Signature' => signature
      }
    end

    before do
      allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(signing_secret)
    end

    it 'consumes an authentic Slack webhook' do
      builder = Integrations::Slack::IncomingMessageBuilder.new(JSON.parse(payload))
      expect(builder).to receive(:perform).and_return(true)

      expect(Integrations::Slack::IncomingMessageBuilder).to receive(:new).and_return(builder)

      post '/api/v1/integrations/webhooks', params: payload, headers: headers
      expect(response).to have_http_status(:success)
    end

    it 'rejects a webhook with an invalid signature' do
      expect(Integrations::Slack::IncomingMessageBuilder).not_to receive(:new)

      post '/api/v1/integrations/webhooks', params: payload,
                                            headers: headers.merge('X-Slack-Signature' => 'v0=invalid')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a webhook when the signing secret is not configured' do
      allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(nil)
      expect(Integrations::Slack::IncomingMessageBuilder).not_to receive(:new)

      post '/api/v1/integrations/webhooks', params: payload, headers: headers

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a correctly signed webhook outside the replay window' do
      stale_timestamp = 6.minutes.ago.to_i.to_s
      stale_digest = OpenSSL::HMAC.hexdigest('SHA256', signing_secret, "v0:#{stale_timestamp}:#{payload}")

      post '/api/v1/integrations/webhooks', params: payload,
                                            headers: headers.merge(
                                              'X-Slack-Request-Timestamp' => stale_timestamp,
                                              'X-Slack-Signature' => "v0=#{stale_digest}"
                                            )

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
