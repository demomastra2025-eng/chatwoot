# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/openapi_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/resource_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/server').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/settings_payload').to_s

RSpec.describe 'Api::V1::Accounts::Mcp', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:assistant) { create(:captain_assistant, account: account, usage_mode: 'internal_assistant') }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def mcp_headers(user)
    {
      'Authorization' => "Bearer #{user.access_token.token}",
      'CONTENT_TYPE' => 'application/json',
      'ACCEPT' => 'application/json'
    }
  end

  def mcp_request(id:, method:, params: {})
    {
      jsonrpc: '2.0',
      id: id,
      method: method,
      params: params
    }
  end

  before do
    allow_any_instance_of(Onelink::Mcp::OpenapiCatalog).to receive(:tools).and_return([])
    allow_any_instance_of(Onelink::Mcp::OpenapiCatalog).to receive(:catalog_entries).and_return([])
    allow_any_instance_of(Onelink::Mcp::CaptainToolAdapter).to receive(:catalog_entries).and_return([])
  end

  describe 'GET /api/v1/accounts/:account_id/mcp' do
    it 'returns endpoint metadata for user API tokens' do
      get "/api/v1/accounts/#{account.id}/mcp", headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        name: 'onelink-mcp',
        account_id: account.id,
        user_id: admin.id,
        assistant_id: assistant.id
      )
    end

    it 'rejects session auth without a user API token' do
      get "/api/v1/accounts/#{account.id}/mcp", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a token from another workspace' do
      other_account = create(:account)
      other_user = create(:user, account: other_account, role: :administrator)

      get "/api/v1/accounts/#{account.id}/mcp", headers: mcp_headers(other_user)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/mcp_settings' do
    it 'returns the workspace MCP access policy for account users' do
      get "/api/v1/accounts/#{account.id}/mcp_settings", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(json_response.dig(:mcp_access, :sources, :captain)).to be(true)
      expect(json_response.dig(:mcp_access, :sources, :openapi_read)).to be(true)
      expect(json_response.dig(:mcp_access, :sources, :openapi_write)).to be(false)
      expect(json_response.dig(:permissions, :manage)).to be(true)
    end

    it 'does not expose disabled catalog entries to non-admin users' do
      allow_any_instance_of(Onelink::Mcp::CaptainToolAdapter).to receive(:catalog_entries).and_return(
        [
          {
            id: 'enabled_tool',
            name: 'enabled_tool',
            source: 'captain',
            group_name: 'Knowledge',
            group_key: 'captain:Knowledge',
            risk_level: 'low',
            enabled_by_policy: true
          },
          {
            id: 'disabled_tool',
            name: 'disabled_tool',
            source: 'captain',
            group_name: 'Admin',
            group_key: 'captain:Admin',
            risk_level: 'high',
            enabled_by_policy: false
          }
        ]
      )

      get "/api/v1/accounts/#{account.id}/mcp_settings", headers: agent.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(json_response.dig(:permissions, :manage)).to be(false)
      expect(json_response[:tools].pluck(:id)).to eq(['enabled_tool'])
    end
  end

  describe 'PUT /api/v1/accounts/:account_id/mcp_settings' do
    it 'allows administrators to update the workspace MCP access policy' do
      put "/api/v1/accounts/#{account.id}/mcp_settings",
          params: {
            mcp_access: {
              enabled: true,
              sources: { captain: true, openapi_read: true, openapi_write: true },
              max_risk_level: 'high',
              allowed_groups: ['captain:CRM Deals'],
              require_confirmation_for_mutations: true
            }
          }.to_json,
          headers: admin.create_new_auth_token.merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:success)
      account.reload
      expect(account.mcp_access['sources']['openapi_write']).to be(true)
      expect(account.mcp_access['max_risk_level']).to eq('high')
      expect(account.mcp_access['allowed_groups']).to eq(['captain:CRM Deals'])
    end

    it 'rejects non-admin updates' do
      put "/api/v1/accounts/#{account.id}/mcp_settings",
          params: { mcp_access: { sources: { openapi_write: true }, max_risk_level: 'high' } }.to_json,
          headers: agent.create_new_auth_token.merge('CONTENT_TYPE' => 'application/json')

      expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/mcp' do
    it 'responds to MCP initialize' do
      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(id: 'init-1', method: 'initialize', params: { protocolVersion: '2025-06-18' }).to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      expect(json_response[:jsonrpc]).to eq('2.0')
      expect(json_response[:id]).to eq('init-1')
      expect(json_response.dig(:result, :protocolVersion)).to eq('2025-06-18')
      expect(json_response.dig(:result, :capabilities, :tools)).to include(listChanged: false)
    end

    it 'rejects malformed JSON-RPC envelopes without a version' do
      post "/api/v1/accounts/#{account.id}/mcp",
           params: { id: 'bad-1', method: 'ping' }.to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      expect(json_response[:id]).to eq('bad-1')
      expect(json_response.dig(:error, :code)).to eq(-32_600)
    end

    it 'rejects empty JSON-RPC batches and accepts notification-only batches without a response body' do
      post "/api/v1/accounts/#{account.id}/mcp",
           params: [].to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      expect(json_response.dig(:error, :code)).to eq(-32_600)

      post "/api/v1/accounts/#{account.id}/mcp",
           params: [{ jsonrpc: '2.0', method: 'notifications/initialized' }].to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_blank
    end

    it 'lists account-scoped Captain tools visible to the token' do
      tool_definition = {
        id: 'search_documentation',
        title: 'Search documentation',
        description: 'Search workspace knowledge',
        group_name: 'Knowledge',
        allowed_scopes: ['assistant'],
        risk_level: 'low',
        idempotent: true,
        requires_confirmation: false
      }
      tool_instance = instance_double(Captain::Tools::BaseTool, params_schema: {
                                        type: 'object',
                                        properties: { query: { type: 'string' } },
                                        required: ['query']
                                      })

      allow(Captain::ToolCatalog).to receive(:available_tools_for).and_return([tool_definition])
      allow(Captain::ToolCatalog).to receive(:allowed_tools_for).and_return([tool_definition])
      allow(Captain::ToolCatalog).to receive(:build_tool).and_return(tool_instance)
      allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
      allow(Captain::ToolPolicy).to receive(:selection_metadata).and_return(
        required_features: [],
        required_permissions: [],
        risk_level: 'low',
        requires_confirmation: false,
        agent_high_risk: false
      )

      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(id: 'tools-1', method: 'tools/list').to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      tool = json_response.dig(:result, :tools).first
      expect(tool).to include(
        name: 'search_documentation',
        title: 'Search documentation',
        description: include('Search workspace knowledge')
      )
      expect(tool.dig(:inputSchema, :properties, :query, :type)).to eq('string')
      expect(tool.dig(:_meta, :account_id)).to eq(account.id)
    end

    it 'does not list high-risk confirmation tools for non-admin users' do
      tool_definition = {
        id: 'delete_campaign',
        title: 'Delete Campaign',
        description: 'Delete a campaign',
        group_name: 'Campaigns',
        allowed_scopes: ['assistant'],
        risk_level: 'high',
        idempotent: false,
        requires_confirmation: true
      }

      allow(Captain::ToolCatalog).to receive(:available_tools_for).and_return([tool_definition])
      allow(Captain::ToolCatalog).to receive(:allowed_tools_for).and_return([tool_definition])
      allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)

      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(id: 'tools-2', method: 'tools/list').to_json,
           headers: mcp_headers(agent)

      expect(response).to have_http_status(:success)
      expect(json_response.dig(:result, :tools)).to eq([])
    end

    it 'executes an allowed Captain tool with the authenticated user context' do
      tool_definition = {
        id: 'search_documentation',
        title: 'Search documentation',
        description: 'Search workspace knowledge',
        allowed_scopes: ['assistant'],
        risk_level: 'low',
        idempotent: true,
        requires_confirmation: false
      }
      tool_instance = instance_double(Captain::Tools::BaseTool, active?: true)

      allow(Captain::ToolCatalog).to receive(:available_tools_for).and_return([tool_definition])
      allow(Captain::ToolCatalog).to receive(:allowed_tools_for).and_return([tool_definition])
      allow(Captain::ToolCatalog).to receive(:build_tool).with(
        hash_including(id: 'search_documentation'),
        hash_including(assistant: assistant, scope_name: 'assistant', user: admin)
      ).and_return(tool_instance)
      allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
      allow(tool_instance).to receive(:execute).with(query: 'shipping').and_return(
        Captain::ToolResult.success(data: { answer: 'Shipping takes 2 days', access_token: 'super-secret-token' })
      )

      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(
             id: 'call-1',
             method: 'tools/call',
             params: { name: 'search_documentation', arguments: { query: 'shipping' } }
           ).to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      expect(json_response.dig(:result, :isError)).to be(false)
      expect(json_response.dig(:result, :structuredContent, :answer)).to eq('Shipping takes 2 days')
      expect(json_response.dig(:result, :structuredContent, :access_token)).to eq('[FILTERED]')
      expect(response.body).not_to include('super-secret-token')
    end

    it 'reads account profile resource' do
      uri = "onelink://accounts/#{account.id}/profile"

      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(id: 'resource-1', method: 'resources/read', params: { uri: uri }).to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      content = json_response.dig(:result, :contents).first
      expect(content).to include(uri: uri, mimeType: 'application/json')
      expect(JSON.parse(content[:text])['account']['id']).to eq(account.id)
    end

    it 'reads the combined Captain and OpenAPI tool catalog resource' do
      uri = "onelink://accounts/#{account.id}/tools/catalog"
      allow_any_instance_of(Onelink::Mcp::CaptainToolAdapter).to receive(:tools).and_return(
        [{ name: 'search_documentation' }]
      )
      allow_any_instance_of(Onelink::Mcp::OpenapiCatalog).to receive(:tools).and_return(
        [{ name: 'api__get_account_details' }]
      )

      post "/api/v1/accounts/#{account.id}/mcp",
           params: mcp_request(id: 'resource-tools-1', method: 'resources/read', params: { uri: uri }).to_json,
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:success)
      content = json_response.dig(:result, :contents).first
      tool_names = JSON.parse(content[:text])['tools'].pluck('name')
      expect(tool_names).to contain_exactly('search_documentation', 'api__get_account_details')
    end

    it 'rejects invalid JSON request bodies' do
      post "/api/v1/accounts/#{account.id}/mcp",
           params: '{invalid-json',
           headers: mcp_headers(admin)

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to be_present
    end
  end
end
