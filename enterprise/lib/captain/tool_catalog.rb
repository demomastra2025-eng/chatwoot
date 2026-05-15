# frozen_string_literal: true

class Captain::ToolCatalog
  class << self
    def available_tools_for(assistant, scope_name)
      (built_in_tools_for(assistant, scope_name) + custom_tools_for(assistant, scope_name) + mcp_tools_for(assistant, scope_name))
        .map(&:dup)
        .uniq { |tool_definition| tool_definition[:id] }
    end

    def available_tool_ids_for(assistant, scope_name)
      available_tools_for(assistant, scope_name).pluck(:id)
    end

    def allowed_tools_for(assistant, scope_name, fallback_ids: nil)
      selected_ids = allowed_tool_ids_for(
        assistant,
        scope_name,
        fallback_ids: fallback_ids || available_tool_ids_for(assistant, scope_name)
      )

      available_tools_for(assistant, scope_name).select do |tool_definition|
        selected_ids.include?(tool_definition[:id])
      end
    end

    def allowed_tool_ids_for(assistant, scope_name, fallback_ids: nil)
      Captain::ToolAccess.allowed_tool_ids_for(
        assistant,
        scope_name,
        fallback_ids: fallback_ids || available_tool_ids_for(assistant, scope_name)
      )
    end

    def build_tool(tool_definition, assistant:, scope_name:, user: nil, conversation: nil, copilot_thread: nil)
      tool_definition = tool_definition.with_indifferent_access
      tool_id = tool_definition[:id].to_s
      return if tool_id.blank?

      if ActiveModel::Type::Boolean.new.cast(tool_definition[:custom])
        build_custom_tool(tool_id, assistant: assistant, scope_name: scope_name, user: user, conversation: conversation,
                                   copilot_thread: copilot_thread)
      elsif tool_definition[:provider].to_s == 'mcp'
        build_mcp_tool(tool_definition, assistant: assistant, scope_name: scope_name, user: user, conversation: conversation,
                                        copilot_thread: copilot_thread)
      else
        build_registered_tool(tool_id, assistant: assistant, scope_name: scope_name, user: user, conversation: conversation,
                                       copilot_thread: copilot_thread)
      end
    end

    def summary_for(tools)
      Array(tools).map do |tool|
        metadata = tool_summary_metadata(tool)
        suffix = metadata.present? ? " (#{metadata.join(', ')})" : ''

        "- #{tool[:id]}: #{tool[:description]}#{suffix}"
      end.join("\n")
    end

    def tool_summary_metadata(tool)
      metadata = []
      metadata << "risk: #{tool[:risk_level]}" if tool[:risk_level].present?
      metadata << 'requires operator confirmation' if ActiveModel::Type::Boolean.new.cast(tool[:requires_confirmation])
      metadata
    end

    private

    def built_in_tools_for(assistant, scope_name)
      Captain::ToolRegistry.tools_for_scope(scope_name).select do |tool_definition|
        required_integrations_available?(assistant, tool_definition)
      end
    end

    def required_integrations_available?(assistant, tool_definition)
      required_integrations = Array(tool_definition[:required_integrations]).map(&:to_s)
      return true if assistant.blank? || required_integrations.blank?

      required_integrations.all? do |app_id|
        assistant.account.hooks.exists?(app_id: app_id, status: Integrations::Hook.statuses[:enabled])
      end
    end

    def custom_tools_for(assistant, scope_name)
      assistant.account.captain_custom_tools.enabled
               .map(&:to_tool_metadata)
               .select { |tool| Array(tool[:allowed_scopes]).map(&:to_s).include?(scope_name.to_s) }
               .map { |tool| assistant_scope?(scope_name) ? tool.merge(requires_confirmation: true) : tool }
    end

    def mcp_tools_for(assistant, scope_name)
      Captain::Mcp::ToolCatalog.available_tools_for(assistant, scope_name).map do |tool|
        next tool unless assistant_scope?(scope_name)
        next tool unless mcp_tool_requires_confirmation?(tool)

        tool.merge(requires_confirmation: true)
      end
    end

    def assistant_scope?(scope_name)
      scope_name.to_s == Captain::ToolAccess::SCOPE_ASSISTANT
    end

    def mcp_tool_requires_confirmation?(tool)
      definition = tool.with_indifferent_access
      %w[high custom].include?(definition[:risk_level].to_s) || !ActiveModel::Type::Boolean.new.cast(definition[:idempotent])
    end

    def build_registered_tool(tool_id, assistant:, scope_name:, user:, conversation:, copilot_thread:)
      tool_class =
        case scope_name.to_s
        when Captain::ToolAccess::SCOPE_AGENT
          Captain::ToolRegistry.resolve_agent_tool_class(tool_id)
        when Captain::ToolAccess::SCOPE_ASSISTANT
          Captain::ToolRegistry.resolve_assistant_tool_class(tool_id)
        end

      return unless tool_class

      if scope_name.to_s == Captain::ToolAccess::SCOPE_ASSISTANT
        tool_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread)
      elsif tool_class <= Captain::Tools::Agent::AccountToolAdapter
        tool_class.new(assistant, tool_id: tool_id)
      else
        tool_class.new(assistant)
      end
    end

    def build_custom_tool(tool_id, assistant:, scope_name:, user:, conversation:, copilot_thread:)
      custom_tool = assistant.account.captain_custom_tools.enabled.find_by(slug: tool_id)
      return unless custom_tool

      case scope_name.to_s
      when Captain::ToolAccess::SCOPE_AGENT
        custom_tool.tool(assistant)
      when Captain::ToolAccess::SCOPE_ASSISTANT
        custom_tool.copilot_tool(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread)
      end
    end

    def build_mcp_tool(tool_definition, assistant:, scope_name:, user:, conversation:, copilot_thread:)
      mcp_server = assistant.account.captain_mcp_servers.enabled.find_by(id: tool_definition[:mcp_server_id])
      return unless mcp_server

      case scope_name.to_s
      when Captain::ToolAccess::SCOPE_AGENT
        Captain::Tools::McpTool.new(assistant, mcp_server, tool_definition)
      when Captain::ToolAccess::SCOPE_ASSISTANT
        Captain::Tools::Copilot::McpTool.new(
          assistant,
          mcp_server,
          tool_definition,
          user: user,
          conversation: conversation,
          copilot_thread: copilot_thread
        )
      end
    end
  end
end
