module Captain::ToolAccess
  SCOPE_AGENT = 'agent'.freeze
  SCOPE_ASSISTANT = 'assistant'.freeze
  SCOPE_ORDER = [
    SCOPE_AGENT,
    SCOPE_ASSISTANT
  ].freeze
  DEFAULT_AGENT_TOOL_IDS = %w[faq_lookup web_search web_scrape_url handoff].freeze
  # The shared read layer: the read-only tools every customer-facing agent has whatever the clinic selected, the FAQ lookup and the
  # service catalog with prices. Any agent can then answer a question itself, and a transfer is only for an action that its own
  # tools cannot do. The writing tools and the patient-data tools stay as the clinic configured them.
  SHARED_READ_TOOL_IDS = %w[faq_lookup search_scheduling_services].freeze
  PER_ASSISTANT_WEB_TOOL_IDS = %w[web_search web_scrape_url].freeze
  # These tools follow a workspace setting, never an @-mention in the instruction. The notes and the staff notification
  # (add_private_note, add_contact_note, send_notification) are not here: an instruction that mentions one binds it.
  # cancel_response is not mentionable either: response_mode "suppress" of the response schema covers it.
  CAPABILITY_CONTROLLED_AGENT_TOOL_IDS = %w[
    faq_lookup web_search web_scrape_url handoff resolve_conversation cancel_response
  ].freeze

  module_function

  # Some stored configs carry a legacy non-Hash tool_access (e.g. an array of
  # pairs). Treat any malformed shape as "not configured" instead of raising.
  def raw_scope(config, scope_name)
    access = config.is_a?(Hash) ? config['tool_access'] : nil
    scope = access.is_a?(Hash) ? access[scope_name.to_s] : nil
    scope.is_a?(Hash) ? scope : nil
  end

  def definitions_for(assistant)
    normalized_access = normalized_access_for(assistant)

    available_tools_for(assistant).flat_map do |scope_name, tools|
      selected_ids = normalized_access.dig(scope_name, 'tool_ids') || []

      tools.map do |tool|
        metadata = Captain::ToolPolicy.selection_metadata(tool)

        tool.merge(
          metadata,
          scope_name: scope_name,
          selected: selected_ids.include?(tool[:id]),
          mentionable: scope_name != SCOPE_AGENT ||
            (!tool[:capability_tool] && !CAPABILITY_CONTROLLED_AGENT_TOOL_IDS.include?(tool[:id].to_s))
        )
      end
    end
  end

  def normalized_access_for(assistant)
    available_tools_for(assistant).each_with_object({}) do |(scope_name, tools), result|
      raw_scope = raw_scope(assistant.config.to_h.deep_stringify_keys, scope_name) || {}
      available_ids = tools.pluck(:id)
      default_ids = default_tool_ids_for(scope_name, tools)
      selected = selected_ids_for(assistant, scope_name, raw_scope, default_ids, available_ids)

      result[scope_name] = {
        'enabled' => scope_enabled?(assistant, scope_name, raw_scope, default_ids),
        'tool_ids' => selected
      }
    end
  end

  def scope_enabled?(assistant, scope_name, raw_scope, default_ids)
    return true if scope_name == SCOPE_AGENT && assistant.external_agent?
    return ActiveModel::Type::Boolean.new.cast(raw_scope['enabled']) if raw_scope.key?('enabled')

    default_ids.any?
  end

  def selected_ids_for(assistant, scope_name, raw_scope, default_ids, available_ids)
    configured_ids = Array(raw_scope['tool_ids']).map(&:to_s)
    selected = sanitize_tool_ids(raw_scope.key?('tool_ids') ? configured_ids : default_ids, available_ids)
    return selected unless scope_name == SCOPE_AGENT && assistant.external_agent?

    account_tool_ids_for(assistant, selected, available_ids)
  end

  def account_tool_ids_for(assistant, selected, available_ids)
    settings = assistant.account_settings
    understanding = settings.section('understanding')
    selected -= %w[web_search web_scrape_url resolve_conversation]
    selected |= %w[handoff] & available_ids
    selected |= shared_read_tool_ids_for(assistant, available_ids)
    selected << 'resolve_conversation' if settings.section('handoff')['auto_completion_enabled'] && available_ids.include?('resolve_conversation')
    selected << 'web_search' if understanding['web_search'] && available_ids.include?('web_search')
    selected << 'web_scrape_url' if understanding['web_page_reading'] && available_ids.include?('web_scrape_url')
    selected
  end

  # The ids of the shared read layer (SHARED_READ_TOOL_IDS) that this agent gets: the tool is in the catalog of the agent, the FAQ
  # lookup only where the platform has the FAQ on for the agent, and every tool only where its own requirements hold (the service
  # catalog needs the scheduling feature of the account, so a clinic without a calendar has no catalog tool that would always fail).
  def shared_read_tool_ids_for(assistant, available_ids)
    SHARED_READ_TOOL_IDS.select do |tool_id|
      available_ids.include?(tool_id) && shared_read_tool_open?(assistant, tool_id)
    end
  end

  def shared_read_tool_open?(assistant, tool_id)
    return false if tool_id == 'faq_lookup' && !assistant.faq_enabled?

    definition = Captain::ToolRegistry.definition_for(tool_id)
    definition.present? && Captain::ToolPolicy.runtime_allowed?(definition.to_h, assistant: assistant, scope_name: SCOPE_AGENT)
  end

  def allowed_tool_ids_for(assistant, scope_name, fallback_ids:)
    tools = available_tools_for_scope(assistant, scope_name)
    available_ids = tools.pluck(:id)
    if scope_name == SCOPE_AGENT && assistant.external_agent?
      raw_scope = raw_scope(assistant.config.to_h, scope_name) || {}
      defaults = default_tool_ids_for(scope_name, tools)
      return selected_ids_for(assistant, scope_name, raw_scope, defaults, available_ids)
    end
    return sanitize_tool_ids(fallback_ids, available_ids) unless scope_configured?(assistant, scope_name)

    raw_scope = raw_scope(assistant.config, scope_name) || {}
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

  def per_assistant_web_tool_enabled?(assistant, tool_id, scope_name: SCOPE_AGENT)
    normalized_id = tool_id.to_s
    return true unless PER_ASSISTANT_WEB_TOOL_IDS.include?(normalized_id)
    return false if assistant.blank?

    if scope_name == SCOPE_AGENT && assistant.external_agent?
      understanding = assistant.account_settings.section('understanding')
      return understanding[normalized_id == 'web_search' ? 'web_search' : 'web_page_reading']
    end

    config = assistant.config.to_h.deep_stringify_keys
    raw_scope = raw_scope(config, scope_name)
    unless raw_scope.is_a?(Hash)
      return ActiveModel::Type::Boolean.new.cast(config['feature_web']) if config.key?('feature_web')

      return true
    end

    enabled = raw_scope.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(raw_scope['enabled']) : true
    selected_ids = raw_scope.key?('tool_ids') ? Array(raw_scope['tool_ids']).map(&:to_s) : DEFAULT_AGENT_TOOL_IDS
    enabled && selected_ids.include?(normalized_id)
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
