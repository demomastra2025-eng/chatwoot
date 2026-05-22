require 'rails_helper'

RSpec.describe 'Content Postiz API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { admin.create_new_auth_token }
  let(:postiz_base_url) { 'https://postiz.example.com/api/public/v1' }

  before do
    account.enable_features!('content')
  end

  around do |example|
    ClimateControl.modify(POSTIZ_BASE_URL: 'https://postiz.example.com') do
      example.run
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/content/connection' do
    it 'stores the Postiz API key server-side and returns only connection metadata' do
      patch "/api/v1/accounts/#{account.id}/content/connection",
            params: {
              access_token: 'postiz-key',
              status: 'enabled',
              settings: {
                base_url: 'http://169.254.169.254/latest/meta-data',
                organization_id: 'org-1',
                default_timezone: 'Asia/Almaty'
              }
            },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body['payload']
      hook = account.hooks.find_by!(app_id: 'postiz')
      expect(hook.access_token).to eq('postiz-key')
      expect(hook.settings).to include('organization_id' => 'org-1', 'default_timezone' => 'Asia/Almaty')
      expect(hook.settings).not_to have_key('base_url')
      expect(payload).to include('connected' => true, 'enabled' => true, 'token_configured' => true)
      expect(payload).not_to have_key('access_token')
    end

    it 'rejects creating a connection without an explicit Postiz API key' do
      patch "/api/v1/accounts/#{account.id}/content/connection",
            params: { status: 'enabled', settings: { organization_id: 'org-1' } },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'POSTIZ_CONNECTION_MISSING')
      expect(account.hooks.find_by(app_id: 'postiz')).to be_nil
    end

    it 'rejects the connection when the content feature is disabled' do
      account.disable_features!('content')

      patch "/api/v1/accounts/#{account.id}/content/connection",
            params: { access_token: 'postiz-key' },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('code' => 'FEATURE_DISABLED')
    end

    it 'rejects non-admin users' do
      patch "/api/v1/accounts/#{account.id}/content/connection",
            params: { access_token: 'postiz-key' },
            headers: agent.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/content/connection/test' do
    it 'returns a normalized error when the Postiz API key is missing' do
      post "/api/v1/accounts/#{account.id}/content/connection/test",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'POSTIZ_CONNECTION_MISSING')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/content/channels' do
    it 'returns a normalized error when the Postiz hook is disabled' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {}, status: 'disabled')

      get "/api/v1/accounts/#{account.id}/content/channels",
          headers: headers,
          as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'POSTIZ_CONNECTION_DISABLED')
    end

    it 'proxies channel reads to Postiz without exposing the API key' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      stub = stub_request(:get, "#{postiz_base_url}/integrations")
             .with(headers: { 'Authorization' => 'postiz-key' })
             .to_return(
               status: 200,
               body: { integrations: [{ id: 'ig-1', name: 'Instagram' }] }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      get "/api/v1/accounts/#{account.id}/content/channels",
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('integrations' => [{ 'id' => 'ig-1', 'name' => 'Instagram' }])
      expect(response.body).not_to include('postiz-key')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/content/posts' do
    it 'forwards Postiz-compatible post creation payloads' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      post_payload = {
        type: 'schedule',
        date: '2026-05-21T12:00:00.000Z',
        shortLink: false,
        tags: [],
        posts: [
          {
            integration: { id: 'ig-1' },
            value: [{ content: 'Hello from OneLink SMM' }],
            settings: {}
          }
        ]
      }
      stub = stub_request(:post, "#{postiz_base_url}/posts")
             .with(body: post_payload.to_json, headers: { 'Authorization' => 'postiz-key', 'Content-Type' => 'application/json' })
             .to_return(status: 201, body: { id: 'post-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/content/posts",
           params: post_payload,
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('id' => 'post-1')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/content/channels/oauth_url' do
    it 'proxies only the provider and refresh query to Postiz' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      stub = stub_request(:get, "#{postiz_base_url}/social/instagram")
             .with(query: { refresh: 'true' }, headers: { 'Authorization' => 'postiz-key' })
             .to_return(status: 200, body: { url: 'https://postiz.example.com/oauth' }.to_json, headers: { 'Content-Type' => 'application/json' })

      get "/api/v1/accounts/#{account.id}/content/channels/oauth_url",
          params: { provider: 'instagram', refresh: true },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('url' => 'https://postiz.example.com/oauth')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/content/channels/:id/find_slot' do
    it 'proxies best-slot lookups without exposing the API key' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      stub = stub_request(:get, "#{postiz_base_url}/find-slot/ig-1")
             .with(headers: { 'Authorization' => 'postiz-key' })
             .to_return(status: 200, body: { date: '2026-05-21T12:00:00.000Z' }.to_json, headers: { 'Content-Type' => 'application/json' })

      get "/api/v1/accounts/#{account.id}/content/channels/ig-1/find_slot",
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('date' => '2026-05-21T12:00:00.000Z')
      expect(response.body).not_to include('postiz-key')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/content/media/upload_from_url' do
    it 'proxies media URL uploads through the server-side Postiz key' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      stub = stub_request(:post, "#{postiz_base_url}/upload-from-url")
             .with(
               body: { url: 'https://cdn.example.com/image.png' }.to_json,
               headers: { 'Authorization' => 'postiz-key', 'Content-Type' => 'application/json' }
             )
             .to_return(status: 201, body: { id: 'media-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/content/media/upload_from_url",
           params: { url: 'https://cdn.example.com/image.png' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('id' => 'media-1')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/content/analytics' do
    it 'proxies integration analytics reads' do
      create(:integrations_hook, account: account, app_id: 'postiz', access_token: 'postiz-key', settings: {})
      stub = stub_request(:get, "#{postiz_base_url}/analytics/ig-1")
             .with(query: { date: '2026-05' }, headers: { 'Authorization' => 'postiz-key' })
             .to_return(status: 200, body: { followers: 10 }.to_json, headers: { 'Content-Type' => 'application/json' })

      get "/api/v1/accounts/#{account.id}/content/analytics",
          params: { integration: 'ig-1', date: '2026-05' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
      expect(response.parsed_body['payload']).to include('followers' => 10)
    end
  end
end
