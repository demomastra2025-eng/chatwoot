require 'rails_helper'

RSpec.describe Captain::McpServer, type: :model do
  describe 'validations' do
    it 'is valid with streamable url config' do
      server = build(:captain_mcp_server)

      expect(server).to be_valid
      expect(server.slug).to be_present
    end

    it 'requires url for streamable and sse transports' do
      server = build(:captain_mcp_server, server_config: {})

      expect(server).not_to be_valid
      expect(server.errors[:server_config]).to include('must include url for HTTP transports')
    end

    it 'requires command for stdio transport' do
      server = build(:captain_mcp_server, :stdio, server_config: {})

      expect(server).not_to be_valid
      expect(server.errors[:server_config]).to include('must include command for stdio transport')
    end

    it 'disables stdio by default in production-like environments' do
      allow(Rails.env).to receive(:production?).and_return(true)

      with_modified_env(Captain::McpServer::STDIO_ENABLED_ENV => nil) do
        server = build(:captain_mcp_server, :stdio)

        expect(server).not_to be_valid
        expect(server.errors[:transport_type]).to include('stdio transport is disabled for this environment')
      end
    end

    it 'enforces the optional stdio command allowlist' do
      with_modified_env(
        Captain::McpServer::STDIO_ENABLED_ENV => 'true',
        Captain::McpServer::STDIO_COMMAND_ALLOWLIST_ENV => 'ruby,bundle'
      ) do
        server = build(:captain_mcp_server, :stdio, server_config: { 'command' => 'npx' })

        expect(server).not_to be_valid
        expect(server.errors[:server_config]).to include('command is not allowlisted for stdio transport')
      end
    end
  end

  describe '#client_options' do
    it 'returns a ruby_llm-mcp compatible option hash' do
      server = build(:captain_mcp_server, account_id: 12, slug: 'github_mcp')

      expect(server.client_options).to include(
        name: 'captain_12_github_mcp',
        transport_type: :streamable,
        start: false,
        request_timeout: 30_000
      )
      expect(server.client_options[:config]).to eq(url: 'https://example.com/mcp')
    end

    it 'converts an explicit timeout override from seconds to MCP milliseconds' do
      server = build(:captain_mcp_server, request_timeout: 30)

      expect(server.client_options(request_timeout_seconds: 5)[:request_timeout]).to eq(5000)
    end

    it 'injects persisted OAuth storage for HTTP transports when OAuth is configured' do
      server = build(
        :captain_mcp_server,
        server_config: {
          'url' => 'https://example.com/mcp',
          'oauth' => { 'scope' => 'repo' }
        }
      )

      oauth_config = server.client_options.dig(:config, :oauth)

      expect(oauth_config[:scope]).to eq('repo')
      expect(oauth_config[:storage]).to be_a(Captain::Mcp::OauthStorage)
    end
  end

  describe '#oauth_status' do
    it 'marks the server as connected when a token is stored' do
      server = build(:captain_mcp_server)
      server.oauth_token = RubyLLM::MCP::Auth::Token.new(access_token: 'token', expires_in: 3600)

      expect(server.oauth_status).to include(
        configured: true,
        connected: true,
        expires_soon: false
      )
    end
  end

  describe '#server_config_for_api' do
    it 'redacts sensitive headers and tokens by default' do
      server = build(
        :captain_mcp_server,
        server_config: {
          'url' => 'https://example.com/mcp',
          'headers' => {
            'Authorization' => 'Bearer secret-token',
            'X-Trace' => 'visible'
          },
          'oauth' => {
            'client_id' => 'client-id',
            'client_secret' => 'super-secret'
          }
        }
      )

      expect(server.server_config_for_api).to eq(
        'url' => 'https://example.com/mcp',
        'headers' => {
          'Authorization' => '[FILTERED]',
          'X-Trace' => 'visible'
        },
        'oauth' => {
          'client_id' => 'client-id',
          'client_secret' => '[FILTERED]'
        }
      )
    end

    it 'returns the raw config when include_secrets is true' do
      server = build(
        :captain_mcp_server,
        server_config: {
          'url' => 'https://example.com/mcp',
          'headers' => { 'Authorization' => 'Bearer secret-token' }
        }
      )

      expect(server.server_config_for_api(include_secrets: true)).to eq(
        'url' => 'https://example.com/mcp',
        'headers' => { 'Authorization' => 'Bearer secret-token' }
      )
    end
  end
end
