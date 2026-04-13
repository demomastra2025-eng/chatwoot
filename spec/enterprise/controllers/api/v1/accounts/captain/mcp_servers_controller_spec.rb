require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::McpServers', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/:account_id/captain/mcp_servers' do
    it 'returns redacted servers for agent users' do
      create(
        :captain_mcp_server,
        account: account,
        server_config: {
          'url' => 'https://example.com/mcp',
          'headers' => { 'Authorization' => 'Bearer token' }
        }
      )

      get "/api/v1/accounts/#{account.id}/captain/mcp_servers",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload].length).to eq(1)
      expect(json_response.dig(:payload, 0, :server_config)).to eq(
        url: 'https://example.com/mcp',
        headers: { Authorization: '[FILTERED]' }
      )
    end
  end

  describe 'GET /api/v1/accounts/:account_id/captain/mcp_servers/:id' do
    it 'blocks agents from viewing full server details' do
      server = create(:captain_mcp_server, account: account)

      get "/api/v1/accounts/#{account.id}/captain/mcp_servers/#{server.id}",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns full server config for admins' do
      server = create(
        :captain_mcp_server,
        account: account,
        server_config: {
          'url' => 'https://example.com/mcp',
          'headers' => { 'Authorization' => 'Bearer token' }
        }
      )

      get "/api/v1/accounts/#{account.id}/captain/mcp_servers/#{server.id}",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:server_config]).to eq(
        url: 'https://example.com/mcp',
        headers: { Authorization: 'Bearer token' }
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/mcp_servers' do
    let(:valid_attributes) do
      {
        mcp_server: {
          name: 'GitHub MCP',
          description: 'Read-only GitHub MCP',
          transport_type: 'streamable',
          request_timeout: 45,
          allowed_scopes: %w[agent assistant],
          server_config: {
            url: 'https://example.com/mcp',
            headers: { Authorization: 'Bearer token' }
          }
        }
      }
    end

    it 'blocks agents from creating servers' do
      post "/api/v1/accounts/#{account.id}/captain/mcp_servers",
           params: valid_attributes,
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates a server for admins' do
      post "/api/v1/accounts/#{account.id}/captain/mcp_servers",
           params: valid_attributes,
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:name]).to eq('GitHub MCP')
      expect(json_response[:transport_type]).to eq('streamable')
      expect(json_response[:server_config]).to eq(
        url: 'https://example.com/mcp',
        headers: { Authorization: '[FILTERED]' }
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/mcp_servers/test' do
    it 'returns discovered tools for valid configs' do
      discovered_tools = [
        { id: 'mcp__github__list_issues', title: 'List issues', description: 'List repo issues' }
      ]

      allow_any_instance_of(Captain::Mcp::ServerSurfaceService)
        .to receive(:snapshot).and_return(
          {
            tools: discovered_tools,
            resources: [],
            resource_templates: [],
            prompts: [],
            tasks: [],
            capabilities: {}
          }
        )

      post "/api/v1/accounts/#{account.id}/captain/mcp_servers/test",
           params: {
             mcp_server: {
               name: 'GitHub MCP',
               transport_type: 'streamable',
               server_config: { url: 'https://example.com/mcp' }
             }
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:tools]).to eq(discovered_tools)
      expect(json_response[:total_count]).to eq(1)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/captain/mcp_servers/:id/surface' do
    it 'returns the admin-only MCP surface' do
      server = create(:captain_mcp_server, account: account)
      surface = {
        tools: [{ id: 'mcp__github__list_issues', title: 'List issues' }],
        resources: [{ uri: 'repo://readme', name: 'README' }],
        resource_templates: [],
        prompts: [],
        tasks: [],
        capabilities: { tools: true }
      }

      allow_any_instance_of(Captain::Mcp::ServerSurfaceService)
        .to receive(:snapshot).and_return(surface)

      get "/api/v1/accounts/#{account.id}/captain/mcp_servers/#{server.id}/surface",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:tools]).to eq(surface[:tools])
      expect(json_response[:resources]).to eq(surface[:resources])
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/mcp_servers/:id/oauth_start' do
    it 'starts a browser OAuth flow for HTTP transports' do
      server = create(:captain_mcp_server, account: account)
      provider = instance_double(RubyLLM::MCP::Auth::OAuthProvider)

      allow(RubyLLM::MCP::Auth::OAuthProvider).to receive(:new).and_return(provider)
      allow(provider).to receive(:start_authorization_flow).and_return('https://auth.example.com/authorize')

      post "/api/v1/accounts/#{account.id}/captain/mcp_servers/#{server.id}/oauth_start",
           params: { return_url: "/app/accounts/#{account.id}/captain/tools" },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:authorization_url]).to eq('https://auth.example.com/authorize')
      expect(server.reload.oauth_return_url).to eq("/app/accounts/#{account.id}/captain/tools")
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/captain/mcp_servers/:id/oauth_disconnect' do
    it 'clears persisted oauth state for admins' do
      server = create(
        :captain_mcp_server,
        account: account,
        oauth_token_data: { access_token: 'token' }.to_json,
        oauth_client_info_data: { client_id: 'client' }.to_json,
        oauth_state_param: 'state-123',
        oauth_state_expires_at: 10.minutes.from_now,
        oauth_return_url: "/app/accounts/#{account.id}/captain/tools",
        oauth_last_authorized_at: Time.current
      )

      delete "/api/v1/accounts/#{account.id}/captain/mcp_servers/#{server.id}/oauth_disconnect",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:oauth_status]).to include(
        configured: false,
        connected: false
      )

      server.reload
      expect(server.oauth_token_data).to be_nil
      expect(server.oauth_client_info_data).to be_nil
      expect(server.oauth_state_param).to be_nil
      expect(server.oauth_return_url).to be_nil
      expect(server.oauth_last_authorized_at).to be_nil
    end
  end
end
