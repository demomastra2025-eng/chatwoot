# frozen_string_literal: true

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/access_modes').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/openapi_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/settings_payload').to_s

class Captain::Tools::Copilot::McpAccessPolicyTool < Captain::Tools::Copilot::BaseAccountTool
  SOURCE_PARAM_KEYS = {
    'captain_tools_enabled' => Onelink::Mcp::AccessPolicy::SOURCE_CAPTAIN,
    'openapi_read_tools_enabled' => Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_READ,
    'openapi_write_tools_enabled' => Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_WRITE
  }.freeze

  ARRAY_SETTING_KEYS = %w[
    allowed_groups
    blocked_groups
    allowed_tool_ids
    blocked_tool_ids
    allowed_openapi_operation_ids
    blocked_openapi_operation_ids
  ].freeze

  UPDATE_PARAM_KEYS = (%w[
    enabled
    access_mode
    max_risk_level
    require_confirmation_for_mutations
  ] + SOURCE_PARAM_KEYS.keys + ARRAY_SETTING_KEYS).freeze

  def active?
    account_administrator?
  end

  private

  def mcp_access_policy_payload(include_tools: false)
    payload = Onelink::Mcp::SettingsPayload.new(auth_context: mcp_auth_context).as_json
    payload[:tools] = [] unless cast_boolean(include_tools, default: false)
    payload
  end

  def mcp_auth_context
    @mcp_auth_context ||= Onelink::Mcp::AuthContext.from_assistant_tool(
      assistant: assistant,
      user: @user,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT
    )
  end

  def mcp_access_update_attributes(raw_kwargs)
    kwargs = normalized_mcp_update_kwargs(raw_kwargs)
    config = Onelink::Mcp::AccessPolicy.normalize(account.mcp_access).deep_dup
    updated_fields = []

    apply_access_mode_update(config, updated_fields, kwargs)
    apply_scalar_updates(config, updated_fields, kwargs)
    apply_source_updates(config, updated_fields, kwargs)
    apply_array_updates(config, updated_fields, kwargs)

    [config, updated_fields]
  end

  def normalized_mcp_update_kwargs(raw_kwargs)
    kwargs = raw_kwargs.to_h.with_indifferent_access
    unknown_keys = kwargs.keys.map(&:to_s) - (UPDATE_PARAM_KEYS + ['include_tools'])
    raise ArgumentError, "Unsupported MCP access fields: #{unknown_keys.join(', ')}" if unknown_keys.present?

    kwargs
  end

  def apply_scalar_updates(config, updated_fields, kwargs)
    set_config_value(config, updated_fields, kwargs, :enabled) do |value|
      cast_boolean(value)
    end
    set_config_value(config, updated_fields, kwargs, :max_risk_level) do |value|
      normalized_risk_level(value)
    end
    set_config_value(config, updated_fields, kwargs, :require_confirmation_for_mutations) do |value|
      cast_boolean(value)
    end
  end

  def apply_access_mode_update(config, updated_fields, kwargs)
    return unless kwargs.key?(:access_mode)

    preset = Onelink::Mcp::AccessModes.policy_for_mode(
      normalized_access_mode(kwargs[:access_mode]),
      enabled: config['enabled']
    )
    config.replace(preset)
    updated_fields << 'access_mode'
  end

  def set_config_value(config, updated_fields, kwargs, key)
    return unless kwargs.key?(key)

    config[key.to_s] = yield(kwargs[key])
    updated_fields << key.to_s
  end

  def apply_source_updates(config, updated_fields, kwargs)
    SOURCE_PARAM_KEYS.each do |param_key, source_key|
      next unless kwargs.key?(param_key)

      config['sources'][source_key] = cast_boolean(kwargs[param_key])
      updated_fields << "sources.#{source_key}"
    end
  end

  def apply_array_updates(config, updated_fields, kwargs)
    ARRAY_SETTING_KEYS.each do |setting_key|
      next unless kwargs.key?(setting_key)

      config[setting_key] = normalize_string_array(kwargs[setting_key], field_name: setting_key)
      updated_fields << setting_key
    end
  end

  def normalized_risk_level(value)
    risk_level =
      value.to_s.presence || Onelink::Mcp::AccessPolicy::DEFAULT_MAX_RISK_LEVEL
    return risk_level if Onelink::Mcp::AccessPolicy::RISK_ORDER.key?(risk_level)

    allowed_values = Onelink::Mcp::AccessPolicy::RISK_ORDER.keys.join(', ')
    raise ArgumentError, "max_risk_level must be one of: #{allowed_values}"
  end

  def normalized_access_mode(value)
    access_mode = value.to_s.presence || Onelink::Mcp::AccessModes::BASIC
    return access_mode if Onelink::Mcp::AccessModes::IDS.include?(access_mode)

    allowed_values = Onelink::Mcp::AccessModes::IDS.join(', ')
    raise ArgumentError, "access_mode must be one of: #{allowed_values}"
  end

  def normalize_string_array(value, field_name:)
    values =
      case value
      when nil
        []
      when String
        value.split(',')
      when Array
        value
      else
        raise ArgumentError, "#{field_name} must be an array of strings"
      end

    values.filter_map do |item|
      normalized = item.to_s.strip
      normalized.presence
    end.uniq
  end
end
