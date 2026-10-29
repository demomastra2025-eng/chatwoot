require 'rails_helper'

RSpec.describe 'Api::V1::Integrations::Webhooks' do
  let(:signing_secret) { 'slack-test-signing-secret-2026' }
  let(:payload_body) { { type: 'url_verification', challenge: 'challenge-123' }.to_json }
  let(:timestamp) { Time.now.to_i.to_s }

  def slack_headers(secret: signing_secret, req_timestamp: timestamp, body: payload_body)
    sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{req_timestamp}:#{body}")}"
    {
      'CONTENT_TYPE' => 'application/json',
      'X-Slack-Request-Timestamp' => req_timestamp,
      'X-Slack-Signature' => sig
    }
  end

  describe 'POST /api/v1/integrations/webhooks' do
    it 'fails closed with 401 when SLACK_SIGNING_SECRET is unconfigured even if SLACK_CLIENT_SECRET exists' do
      with_modified_env SLACK_SIGNING_SECRET: nil do
        allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(nil)
        allow(GlobalConfigService).to receive(:load).with('SLACK_CLIENT_SECRET', anything).and_return('TEST_CLIENT_SECRET')

        post '/api/v1/integrations/webhooks',
             params: payload_body,
             headers: slack_headers(secret: 'TEST_CLIENT_SECRET')

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'rejects unsigned requests with 401' do
      with_modified_env SLACK_SIGNING_SECRET: signing_secret do
        expect(Integrations::Slack::IncomingMessageBuilder).not_to receive(:new)

        post '/api/v1/integrations/webhooks',
             params: payload_body,
             headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'rejects stale timestamps older than 5 minutes to prevent replay attacks' do
      with_modified_env SLACK_SIGNING_SECRET: signing_secret do
        stale_ts = (Time.now.to_i - 301).to_s

        post '/api/v1/integrations/webhooks',
             params: payload_body,
             headers: slack_headers(req_timestamp: stale_ts)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'rejects forged HMAC signatures with 401' do
      with_modified_env SLACK_SIGNING_SECRET: signing_secret do
        post '/api/v1/integrations/webhooks',
             params: payload_body,
             headers: slack_headers(secret: 'wrong-secret')

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'consumes webhook when signed with valid Slack HMAC-SHA256 signature' do
      with_modified_env SLACK_SIGNING_SECRET: signing_secret do
        builder = instance_double(Integrations::Slack::IncomingMessageBuilder, perform: { challenge: 'challenge-123' })
        expect(Integrations::Slack::IncomingMessageBuilder).to receive(:new).and_return(builder)

        post '/api/v1/integrations/webhooks',
             params: payload_body,
             headers: slack_headers

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
