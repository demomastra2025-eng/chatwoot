# frozen_string_literal: true

class Captain::ToolCatalog
  SOURCE_TYPE_SYSTEM = 'system'
  SOURCE_TYPE_CUSTOM = 'custom'
  SOURCE_TYPE_MCP = 'mcp'
  SOURCE_TYPE_SKILL = 'skill'
  SOURCE_TYPES = [SOURCE_TYPE_SYSTEM, SOURCE_TYPE_CUSTOM, SOURCE_TYPE_MCP, SOURCE_TYPE_SKILL].freeze

  class << self
    def available_tools_for(assistant, scope_name)
      (built_in_tools_for(assistant,
                          scope_name) + custom_tools_for(assistant,
                                                         scope_name) + mcp_tools_for(assistant,
                                                                                     scope_name) + skill_script_tools_for(assistant, scope_name))
        .map do |tool_definition|
        with_source_type(tool_definition).dup
      end
        .uniq do |tool_definition|
        tool_definition[:id]
      end
    end

    def available_tool_ids_for(assistant, scope_name)
      available_tools_for(assistant, scope_name).pluck(:id)
    end

    def available_tools_for_ids(assistant, scope_name, tool_ids)
      requested_ids = Array(tool_ids).map(&:to_s).uniq
      return [] if requested_ids.empty?

      tools = built_in_tools_for_ids(assistant, scope_name, requested_ids)
      resolved_ids = tools.pluck(:id).map(&:to_s)
      unresolved_ids = requested_ids - resolved_ids

      custom_tools = custom_tools_for_ids(assistant, scope_name, unresolved_ids)
      tools.concat(custom_tools)
      unresolved_ids -= custom_tools.pluck(:id).map(&:to_s)

      mcp_ids, skill_or_stale_ids = unresolved_ids.partition { |tool_id| tool_id.start_with?('mcp__') }
      tools.concat(mcp_tools_for(assistant, scope_name)) if mcp_ids.any?
      tools.concat(skill_script_tools_for_ids(assistant, scope_name, skill_or_stale_ids)) if skill_or_stale_ids.any?

      tools.filter_map do |tool_definition|
        next unless requested_ids.include?(tool_definition[:id].to_s)

        with_source_type(tool_definition).dup
      end.uniq { |tool_definition| tool_definition[:id] }
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
      elsif tool_definition[:provider].to_s == 'skill_script'
        build_skill_script_tool(tool_definition, assistant: assistant, scope_name: scope_name)
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

    def requires_confirmation_for_scope?(tool_definition, scope_name, include_missing_idempotency: false)
      assistant_scope?(scope_name) && tool_requires_confirmation?(
        tool_definition,
        include_missing_idempotency: include_missing_idempotency
      )
    end

    private

    def built_in_tools_for_ids(assistant, scope_name, tool_ids)
      tool_ids.filter_map do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        next if definition.blank? || !definition.supports_scope?(scope_name)

        tool_definition = definition.to_h
        next unless required_integrations_available?(assistant, tool_definition)
        next unless runtime_requirements_available?(assistant, tool_definition)

        require_assistant_confirmation(tool_definition, scope_name)
      end
    end

    def built_in_tools_for(assistant, scope_name)
      Captain::ToolRegistry.tools_for_scope(scope_name)
                           .select { |tool_definition| required_integrations_available?(assistant, tool_definition) }
                           .select { |tool_definition| runtime_requirements_available?(assistant, tool_definition) }
                           .map { |tool_definition| require_assistant_confirmation(tool_definition, scope_name) }
    end

    def with_source_type(tool_definition)
      definition = tool_definition.to_h.symbolize_keys
      source_type = definition[:source_type].presence || inferred_source_type(definition)

      definition.merge(source_type: source_type)
    end

    def inferred_source_type(tool_definition)
      return SOURCE_TYPE_CUSTOM if ActiveModel::Type::Boolean.new.cast(tool_definition[:custom])

      case tool_definition[:provider].to_s
      when SOURCE_TYPE_MCP
        SOURCE_TYPE_MCP
      when 'skill_script'
        SOURCE_TYPE_SKILL
      else
        SOURCE_TYPE_SYSTEM
      end
    end

    def runtime_requirements_available?(assistant, tool_definition)
      flags = Array(tool_definition[:required_runtime_flags]).map(&:to_s)
      return true if assistant.blank? || flags.blank?

      flags.all? do |flag|
        case flag
        when 'web_search'
          Captain::Tools::FirecrawlService.configured?
        when 'web_scrape'
          Captain::Tools::FirecrawlService.configured?
        else
          true
        end
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
      custom_tools_for_ids(assistant, scope_name)
    end

    def custom_tools_for_ids(assistant, scope_name, tool_ids = nil)
      tools = assistant.account.captain_custom_tools.enabled
      tools = tools.where(slug: tool_ids) if tool_ids.present?

      tools.map(&:to_tool_metadata)
           .select { |tool| Array(tool[:allowed_scopes]).map(&:to_s).include?(scope_name.to_s) }
           .map { |tool| assistant_scope?(scope_name) ? tool.merge(requires_confirmation: true) : tool }
    end

    def mcp_tools_for(assistant, scope_name)
      Captain::Mcp::ToolCatalog.available_tools_for(assistant, scope_name).map do |tool|
        require_assistant_confirmation(tool, scope_name, include_missing_idempotency: true)
      end
    end

    def skill_script_tools_for(assistant, scope_name)
      return [] unless scope_name.to_s == Captain::ToolAccess::SCOPE_AGENT

      Captain::SkillCatalog.script_tools_for(account: assistant.account)
    end

    def skill_script_tools_for_ids(assistant, scope_name, tool_ids)
      requested_ids = Array(tool_ids).map(&:to_s)
      skill_script_tools_for(assistant, scope_name).select { |tool| requested_ids.include?(tool[:id].to_s) }
    end

    def require_assistant_confirmation(tool, scope_name, include_missing_idempotency: false)
      return tool unless requires_confirmation_for_scope?(
        tool,
        scope_name,
        include_missing_idempotency: include_missing_idempotency
      )

      tool.merge(requires_confirmation: true)
    end

    def assistant_scope?(scope_name)
      scope_name.to_s == Captain::ToolAccess::SCOPE_ASSISTANT
    end

    def tool_requires_confirmation?(tool, include_missing_idempotency: false)
      definition = tool.with_indifferent_access
      return ActiveModel::Type::Boolean.new.cast(definition[:requires_confirmation]) unless definition[:requires_confirmation].nil?
      return true if %w[high custom].include?(definition[:risk_level].to_s)
      return false unless include_missing_idempotency

      !ActiveModel::Type::Boolean.new.cast(definition[:idempotent])
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

    def build_skill_script_tool(tool_definition, assistant:, scope_name:)
      return unless scope_name.to_s == Captain::ToolAccess::SCOPE_AGENT

      Captain::Tools::SkillScriptTool.new(assistant, tool_definition)
    end
  end
end
