require 'rails_helper'

RSpec.describe 'REST API Bearer access token authentication' do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'Account & Profile REST API' do
    it 'authenticates a user personal access token via Authorization: Bearer' do
      get '/api/v1/profile', headers: { 'Authorization' => "Bearer #{agent.access_token.token}  " }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(agent.id)
    end

    it 'authenticates a user personal access token via api-access-token header' do
      get "/api/v1/accounts/#{account.id}/conversations",
          headers: { 'api-access-token' => agent.access_token.token },
          as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'rejects an unknown Bearer personal access token with 401' do
      get '/api/v1/profile', headers: { 'Authorization' => 'Bearer invalid-personal-token' }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to eq('Invalid Access Token')
    end

    it 'rejects a non-user access token via Authorization: Bearer on account endpoints' do
      platform_app = create(:platform_app)

      get "/api/v1/accounts/#{account.id}/conversations",
          headers: { 'Authorization' => "Bearer #{platform_app.access_token.token}" },
          as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to eq('Access to this endpoint is not authorized for this token')
    end

    it 'blocks mixing DeviseTokenAuth headers or query params with a non-user access token' do
      platform_app = create(:platform_app)
      session_headers = agent.create_new_auth_token

      get '/api/v1/profile',
          headers: session_headers.slice('access-token', 'client', 'uid').merge(
            'api-access-token' => platform_app.access_token.token
          ),
          as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to eq('Access to this endpoint is not authorized for this token')

      get '/api/v1/profile',
          params: session_headers.slice('access-token', 'client', 'uid'),
          headers: { 'Authorization' => "Bearer #{platform_app.access_token.token}" },
          as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'keeps DeviseTokenAuth session headers and single-header Bearer auth working, including whitespace-padded JSON' do
      session_headers = agent.create_new_auth_token

      get '/api/v1/profile', headers: session_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(agent.id)

      get '/api/v1/profile', headers: { 'Authorization' => session_headers['Authorization'] }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(agent.id)

      padded_json = " #{JSON.generate(session_headers.slice('access-token', 'client', 'uid', 'expiry', 'token-type'))}"
      padded_bearer = "Bearer #{Base64.strict_encode64(padded_json)}"
      get '/api/v1/profile', headers: { 'Authorization' => padded_bearer }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(agent.id)
    end
  end

  describe 'Platform REST API' do
    let(:platform_app) { create(:platform_app) }

    it 'authenticates a PlatformApp access token via Authorization: Bearer' do
      get '/platform/api/v1/accounts',
          headers: { 'Authorization' => "Bearer #{platform_app.access_token.token}" },
          as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'rejects an invalid Bearer token on Platform API' do
      get '/platform/api/v1/accounts',
          headers: { 'Authorization' => 'Bearer invalid-platform-token' },
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
