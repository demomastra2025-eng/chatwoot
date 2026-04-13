module Captain::ToolAccess
  SCOPE_AGENT = 'agent'.freeze
  SCOPE_ASSISTANT = 'assistant'.freeze
  SCOPE_ORDER = [
    SCOPE_AGENT,
    SCOPE_ASSISTANT
  ].freeze
  DEFAULT_AGENT_TOOL_IDS = %w[faq_lookup handoff].freeze

  module_function

  def definitions_for(assistant)
    normalized_access = normalized_access_for(assistant)

    available_tools_for(assistant).flat_map do |scope_name, tools|
      selected_ids = normalized_access.dig(scope_name, 'tool_ids') || []

      tools.map do |tool|
        metadata = Captain::ToolPolicy.selection_metadata(tool)

        tool.merge(
          metadata,
          scope_name: scope_name,
          selected: selected_ids.include?(tool[:id])
        )
      end
    end
  end

  def normalized_access_for(assistant)
    raw_access = assistant.config.is_a?(Hash) ? assistant.config['tool_access'] : {}
    raw_access = raw_access.to_h.deep_stringify_keys if raw_access.respond_to?(:to_h)

    available_tools_for(assistant).each_with_object({}) do |(scope_name, tools), result|
      raw_scope = raw_access[scope_name].is_a?(Hash) ? raw_access[scope_name] : {}
      available_ids = tools.map { |tool| tool[:id] }
      default_ids = default_tool_ids_for(scope_name, tools)
      configured_tool_ids = Array(raw_scope['tool_ids']).map(&:to_s)

      result[scope_name] = {
        'enabled' => if raw_scope.key?('enabled')
                       ActiveModel::Type::Boolean.new.cast(raw_scope['enabled'])
                     else
                       default_ids.any?
                     end,
        'tool_ids' => sanitize_tool_ids(
          raw_scope.key?('tool_ids') ? configured_tool_ids : default_ids,
          available_ids
        )
      }
    end
  end

  def allowed_tool_ids_for(assistant, scope_name, fallback_ids:)
    return sanitize_tool_ids(fallback_ids, available_tool_ids_for(assistant, scope_name)) unless scope_configured?(assistant, scope_name)

    normalized_scope = normalized_access_for(assistant)[scope_name] || {}
    return [] unless normalized_scope['enabled']

    sanitize_tool_ids(normalized_scope['tool_ids'], available_tool_ids_for(assistant, scope_name))
  end

  def available_tools_for(assistant)
    {
      SCOPE_AGENT => assistant.available_agent_tools,
      SCOPE_ASSISTANT => assistant.available_assistant_tools
    }
  end

  def scope_configured?(assistant, scope_name)
    tool_access = assistant.config.is_a?(Hash) ? assistant.config['tool_access'] : nil
    tool_access.is_a?(Hash) && tool_access.key?(scope_name)
  end

  def available_tool_ids_for(assistant, scope_name)
    Array(available_tools_for(assistant)[scope_name]).map { |tool| tool[:id] }
  end

  def default_tool_ids_for(scope_name, tools)
    available_ids = Array(tools).map { |tool| tool[:id] || tool['id'] }
    default_ids =
      case scope_name
      when SCOPE_AGENT
        DEFAULT_AGENT_TOOL_IDS
      when SCOPE_ASSISTANT
        Array(tools).select do |tool|
          tool = tool.with_indifferent_access
          tool.fetch(:selected_by_default, true)
        end.map { |tool| tool[:id] || tool['id'] }
      else
        []
      end

    sanitize_tool_ids(default_ids, available_ids)
  end

  def sanitize_tool_ids(tool_ids, available_ids)
    Array(tool_ids).map(&:to_s).uniq.select { |tool_id| available_ids.include?(tool_id) }
  end
end
