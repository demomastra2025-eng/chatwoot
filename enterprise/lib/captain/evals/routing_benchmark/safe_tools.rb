# frozen_string_literal: true

# The tool ids a benchmark agent may use. The list is derived from Captain::ToolRegistry, so a new
# customer-facing registry tool needs no edit here. A registry tool is refused when it
#   - is not an agent-scope tool (assistant/copilot tools are unavailable to a customer agent),
#   - reaches an external system that the playground policy cannot contain (web search, page fetch,
#     Linear, live translation, or anything gated by a runtime flag or a connected integration), or
#   - needs an account feature the synthetic workspace does not enable.
# Custom HTTP and MCP tools are rows of the account (captain_custom_tools / captain_mcp_servers), not
# registry entries, so they are never known to the benchmark. Delivery, provider-write and notification
# tools stay allowed: Outbound::PlaygroundDeliveryPolicy blocks them for the marked benchmark records.
class Captain::Evals::RoutingBenchmark::SafeTools
  class << self
    def ids
      Captain::ToolRegistry.definitions.select { |definition| refusal_reason(definition).nil? }.map(&:id)
    end

    # { tool_id => reason } for each registry tool that a fixture may not use.
    def refused
      Captain::ToolRegistry.definitions.each_with_object({}) do |definition, result|
        reason = refusal_reason(definition)
        result[definition.id] = reason if reason
      end
    end

    private

    def refusal_reason(definition)
      return 'assistant_scope_only' unless definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT)
      return 'external_service' if external?(definition)

      'workspace_feature_disabled' if (definition.required_features - Captain::Evals::RoutingBenchmark::Workspace::FEATURES).any?
    end

    def external?(definition)
      Captain::Playground::ToolSupport::EXTERNAL_TOOLS.include?(definition.id) ||
        definition.required_runtime_flags.any? || definition.required_integrations.any?
    end
  end
end
