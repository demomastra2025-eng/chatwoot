FactoryBot.define do
  factory :captain_mcp_server, class: 'Captain::McpServer' do
    association :account
    sequence(:name) { |n| "MCP Server #{n}" }
    description { 'External MCP server' }
    transport_type { 'streamable' }
    server_config { { 'url' => 'https://example.com/mcp' } }
    allowed_scopes { %w[agent assistant] }
    request_timeout { 30 }
    enabled { true }

    trait :stdio do
      transport_type { 'stdio' }
      server_config do
        {
          'command' => 'npx',
          'args' => ['@modelcontextprotocol/server-filesystem', '/tmp']
        }
      end
    end
  end
end
