class Captain::Mcp::ToolCatalog
  CACHE_TTL = 5.minutes

  class << self
    def available_tools_for(assistant, scope_name)
      assistant.account.captain_mcp_servers.enabled.filter_map do |mcp_server|
        next unless mcp_server.normalized_allowed_scopes.include?(scope_name.to_s)

        begin
          DiscoveryService.new(mcp_server).tools.map do |tool_payload|
            mcp_server.to_tool_metadata(tool_payload)
          end
        rescue StandardError => e
          Rails.logger.warn(
            "#{name}: discovery failed for account=#{assistant.account_id} mcp_server=#{mcp_server.id}: #{e.class} #{e.message}"
          )
          nil
        end
      end.flatten
    end
  end

  class DiscoveryService
    def initialize(mcp_server)
      @mcp_server = mcp_server
    end

    def tools(refresh: false)
      return fetch_tools if refresh

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { fetch_tools }
    end

    private

    def cache_key
      ['captain', 'mcp_server_tools', @mcp_server.id, @mcp_server.updated_at.to_i].join(':')
    end

    def fetch_tools
      ClientBuilder.with_client(@mcp_server) do |client|
        client.tools(refresh: true).map do |tool|
          {
            id: tool_id_for(tool.name),
            title: tool.annotations&.title.presence || tool.name.to_s.humanize,
            description: tool.description.to_s,
            risk_level: risk_level_for(tool),
            idempotent: tool.annotations&.idempotent_hint || false,
            mcp_tool_name: tool.name,
            input_schema: tool.params_schema
          }
        end
      end
    end

    def tool_id_for(tool_name)
      "mcp__#{@mcp_server.slug}__#{tool_name}"
    end

    def risk_level_for(tool)
      annotations = tool.annotations
      return 'low' if annotations&.read_only_hint
      return 'high' if annotations&.destructive_hint

      'medium'
    end
  end
end
