module Captain::ToolAccess
  SCOPE_AGENT = 'agent'.freeze
  SCOPE_ASSISTANT = 'assistant'.freeze
  SCOPE_ORDER = [
    SCOPE_AGENT,
    SCOPE_ASSISTANT
  ].freeze
  DEFAULT_AGENT_TOOL_IDS = %w[faq_lookup handoff].freeze
  PER_ASSISTANT_WEB_TOOL_IDS = %w[web_search web_scrape_url].freeze

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
      available_ids = tools.pluck(:id)
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
    tools = available_tools_for_scope(assistant, scope_name)
    available_ids = tools.pluck(:id)
    return sanitize_tool_ids(fallback_ids, available_ids) unless scope_configured?(assistant, scope_name)

    raw_scope = assistant.config['tool_access'][scope_name]
    raw_scope = {} unless raw_scope.is_a?(Hash)
    default_ids = default_tool_ids_for(scope_name, tools)
    enabled = raw_scope.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(raw_scope['enabled']) : default_ids.any?
    return [] unless enabled

    selected_ids = raw_scope.key?('tool_ids') ? Array(raw_scope['tool_ids']).map(&:to_s) : default_ids
    sanitize_tool_ids(selected_ids, available_ids)
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
    available_tools_for_scope(assistant, scope_name).pluck(:id)
  end

  def per_assistant_web_tool_enabled?(assistant, tool_id, scope_name: nil)
    normalized_tool_id = tool_id.to_s
    return true unless PER_ASSISTANT_WEB_TOOL_IDS.include?(normalized_tool_id)
    return false if assistant.blank?

    normalized_scope = (scope_name.presence || runtime_scope_for(assistant)).to_s
    raw_access = assistant.config.is_a?(Hash) ? assistant.config['tool_access'] : nil
    raw_access = raw_access.to_h.deep_stringify_keys if raw_access.respond_to?(:to_h)
    raw_scope = raw_access[normalized_scope] if raw_access.is_a?(Hash)

    unless raw_scope.is_a?(Hash)
      return ActiveModel::Type::Boolean.new.cast(assistant.config.to_h['feature_web'])
    end

    raw_scope = raw_scope.deep_stringify_keys
    enabled = raw_scope.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(raw_scope['enabled']) : true
    enabled && Array(raw_scope['tool_ids']).map(&:to_s).include?(normalized_tool_id)
  end

  def runtime_scope_for(assistant)
    assistant.respond_to?(:internal_assistant?) && assistant.internal_assistant? ? SCOPE_ASSISTANT : SCOPE_AGENT
  end

  def available_tools_for_scope(assistant, scope_name)
    normalized_scope = scope_name.to_s
    return [] unless SCOPE_ORDER.include?(normalized_scope)

    Array(assistant.public_send("available_#{normalized_scope}_tools"))
  end

  def default_tool_ids_for(scope_name, tools)
    available_tools = Array(tools)
    available_ids = available_tools.map { |tool| tool[:id] || tool['id'] }
    default_ids =
      case scope_name
      when SCOPE_AGENT
        DEFAULT_AGENT_TOOL_IDS
      when SCOPE_ASSISTANT
        assistant_default_tool_ids(available_tools)
      else
        []
      end

    sanitize_tool_ids(default_ids, available_ids)
  end

  def sanitize_tool_ids(tool_ids, available_ids)
    Array(tool_ids).map(&:to_s).uniq.select { |tool_id| available_ids.include?(tool_id) }
  end

  def assistant_default_tool_ids(tools)
    Array(tools).filter_map do |tool|
      tool_definition = tool.with_indifferent_access
      next if tool_definition[:id].blank?
      next if tool_definition[:provider].to_s == 'mcp'
      next if tool_definition.key?(:selected_by_default) && !ActiveModel::Type::Boolean.new.cast(tool_definition[:selected_by_default])

      tool_definition[:id].to_s
    end
  end
end
