require 'rails_helper'

RSpec.describe Content::Postiz::Client do
  let(:api_key) { 'postiz-public-key' }

  around do |example|
    ClimateControl.modify(POSTIZ_BASE_URL: 'https://postiz.example.com') do
      example.run
    end
  end

  describe '#list_integrations' do
    it 'calls Postiz public API with the server-side API key' do
      stub = stub_request(:get, 'https://postiz.example.com/api/public/v1/integrations')
             .with(headers: { 'Authorization' => api_key, 'Accept' => 'application/json' })
             .to_return(status: 200, body: { integrations: [{ id: 'ig-1' }] }.to_json, headers: { 'Content-Type' => 'application/json' })

      response = described_class.new(api_key: api_key).list_integrations

      expect(stub).to have_been_requested
      expect(response).to eq('integrations' => [{ 'id' => 'ig-1' }])
    end
  end

  describe '#create_post' do
    it 'forwards the Postiz post payload as JSON' do
      payload = { type: 'schedule', posts: [{ integration: { id: 'ig-1' }, value: [{ content: 'Hello' }] }] }
      stub = stub_request(:post, 'https://postiz.example.com/api/public/v1/posts')
             .with(
               body: payload.to_json,
               headers: { 'Authorization' => api_key, 'Content-Type' => 'application/json' }
             )
             .to_return(status: 201, body: { id: 'post-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

      response = described_class.new(api_key: api_key).create_post(payload)

      expect(stub).to have_been_requested
      expect(response).to eq('id' => 'post-1')
    end
  end

  describe '#delete_post' do
    it 'accepts successful empty Postiz responses' do
      stub = stub_request(:delete, 'https://postiz.example.com/api/public/v1/posts/post-1')
             .to_return(status: 204, body: '')

      response = described_class.new(api_key: api_key).delete_post('post-1')

      expect(stub).to have_been_requested
      expect(response).to eq({})
    end
  end

  describe '#test_connection' do
    it 'returns a redacted failure payload instead of raising' do
      stub_request(:get, 'https://postiz.example.com/api/public/v1/integrations')
        .to_return(status: 401, body: { msg: 'invalid key' }.to_json, headers: { 'Content-Type' => 'application/json' })

      response = described_class.new(api_key: api_key).test_connection

      expect(response).to include(connected: false)
      expect(response[:error]).to include(code: 'POSTIZ_UNAUTHORIZED', message: 'invalid key')
      expect(response.to_s).not_to include(api_key)
    end
  end

  describe 'base URL normalization' do
    it 'accepts a root Postiz URL and appends the public API path' do
      stub = stub_request(:get, 'https://custom-postiz.example.com/api/public/v1/integrations')
             .to_return(status: 200, body: { integrations: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.new(api_key: api_key, base_url: 'https://custom-postiz.example.com/').list_integrations

      expect(stub).to have_been_requested
    end

    it 'normalizes the legacy public API path used by early OneLink builds' do
      stub = stub_request(:get, 'https://custom-postiz.example.com/api/public/v1/integrations')
             .to_return(status: 200, body: { integrations: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.new(api_key: api_key, base_url: 'https://custom-postiz.example.com/public/v1').list_integrations

      expect(stub).to have_been_requested
    end

    it 'rejects successful HTML responses as an invalid Postiz API base URL' do
      stub_request(:get, 'https://postiz.example.com/api/public/v1/integrations')
        .to_return(status: 200, body: '<!DOCTYPE html><html></html>', headers: { 'Content-Type' => 'text/html' })

      response = described_class.new(api_key: api_key).test_connection

      expect(response).to include(connected: false)
      expect(response[:error]).to include(code: 'POSTIZ_INVALID_RESPONSE')
    end
  end
end
