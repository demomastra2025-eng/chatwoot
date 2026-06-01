# frozen_string_literal: true

module Onelink
  module Mcp
    class SettingsPayload
      SOURCE_LABELS = {
        Onelink::Mcp::AccessPolicy::SOURCE_CAPTAIN => 'Captain semantic tools',
        Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_READ => 'OpenAPI read-only API tools',
        Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_WRITE => 'OpenAPI write API tools'
      }.freeze

      def initialize(auth_context:)
        @auth_context = auth_context
        @captain_tool_adapter = Onelink::Mcp::CaptainToolAdapter.new(auth_context: auth_context)
        @openapi_catalog = Onelink::Mcp::OpenapiCatalog.new(auth_context: auth_context)
      end

      def as_json(*_args)
        tools = visible_catalog_entries
        {
          mcp_access: visible_access_config,
          defaults: Onelink::Mcp::AccessPolicy.defaults,
          permissions: {
            manage: auth_context.administrator?
          },
          summary: summary_for(tools),
          sources: sources_for(tools),
          groups: groups_for(tools),
          tools: tools
        }
      end

      private

      attr_reader :auth_context, :captain_tool_adapter, :openapi_catalog

      def catalog_entries
        @catalog_entries ||= (captain_tool_adapter.catalog_entries + openapi_catalog.catalog_entries).sort_by do |entry|
          [entry[:source].to_s, entry[:group_name].to_s, entry[:title].to_s]
        end
      end

      def visible_catalog_entries
        return catalog_entries if auth_context.administrator?

        catalog_entries.select { |entry| entry[:enabled_by_policy] }
      end

      def visible_access_config
        return auth_context.mcp_access_policy.config if auth_context.administrator?

        auth_context.mcp_access_policy.config.slice('enabled', 'sources', 'max_risk_level')
      end

      def summary_for(tools)
        {
          total_tools: tools.size,
          enabled_tools: tools.count { |tool| tool[:enabled_by_policy] },
          captain_tools: tools.count { |tool| tool[:source] == Onelink::Mcp::AccessPolicy::SOURCE_CAPTAIN },
          openapi_read_tools: tools.count { |tool| tool[:source] == Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_READ },
          openapi_write_tools: tools.count { |tool| tool[:source] == Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_WRITE }
        }
      end

      def sources_for(tools)
        Onelink::Mcp::AccessPolicy::DEFAULT_SOURCES.keys.map do |source|
          source_tools = tools.select { |tool| tool[:source] == source }
          {
            id: source,
            label: SOURCE_LABELS.fetch(source, source.humanize),
            enabled: auth_context.mcp_access_policy.source_enabled?(source),
            tools_count: source_tools.size,
            enabled_tools_count: source_tools.count { |tool| tool[:enabled_by_policy] }
          }
        end
      end

      def groups_for(tools)
        tools.group_by { |tool| tool[:group_key] }.map do |group_key, group_tools|
          first_tool = group_tools.first
          {
            id: group_key,
            source: group_key.to_s.split(':', 2).first,
            name: first_tool[:group_name].presence || 'Other',
            tools_count: group_tools.size,
            enabled_tools_count: group_tools.count { |tool| tool[:enabled_by_policy] },
            risk_levels: group_tools.pluck(:risk_level).compact.uniq.sort,
            methods: group_tools.pluck(:method).compact.uniq.sort
          }
        end.sort_by { |group| [group[:source].to_s, group[:name].to_s] }
      end
    end
  end
end
