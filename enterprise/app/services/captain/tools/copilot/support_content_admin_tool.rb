# frozen_string_literal: true

class Captain::Tools::Copilot::SupportContentAdminTool < Captain::Tools::Copilot::BaseAccountTool
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|auth|api[_-]?key|access[_-]?key|url|webhook/i
  SENSITIVE_VALUE_PATTERN = %r{https?://|bearer\s+|token=|api[_-]?key=|secret=}i

  def active?
    account_administrator?
  end

  private

  def canned_response!(canned_response_id)
    account.canned_responses.find(canned_response_id)
  end

  def macro!(macro_id)
    account.macros.find(macro_id)
  end

  def canned_response_payload(canned_response)
    {
      id: canned_response.id,
      short_code: canned_response.short_code,
      content: canned_response.content,
      created_at: canned_response.created_at&.iso8601,
      updated_at: canned_response.updated_at&.iso8601
    }.compact
  end

  def macro_payload(macro, include_actions: true)
    payload = macro_base_payload(macro)
    payload[:actions] = sanitized_config(macro.actions) if include_actions
    payload
  end

  def macro_base_payload(macro)
    {
      id: macro.id,
      name: macro.name,
      visibility: macro.visibility,
      actions_count: Array.wrap(macro.actions).size,
      action_names: macro_action_names(macro),
      created_by_id: macro.created_by_id,
      created_by_name: macro.created_by&.name,
      updated_by_id: macro.updated_by_id,
      updated_by_name: macro.updated_by&.name,
      created_at: macro.created_at&.iso8601,
      updated_at: macro.updated_at&.iso8601
    }.compact
  end

  def macro_action_names(macro)
    Array.wrap(macro.actions).filter_map { |action| action['action_name'] || action[:action_name] }
  end

  def parse_actions_json(value, default: [])
    return default if value.nil?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, 'actions_json must be a JSON array' unless parsed.is_a?(Array)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, 'actions_json must be valid JSON'
  end

  def validate_macro_visibility!(visibility)
    return if visibility.blank? || Macro.visibilities.key?(visibility.to_s)

    raise ArgumentError, "visibility must be one of: #{Macro.visibilities.keys.join(', ')}"
  end

  def sanitized_config(value)
    case value
    when Array
      value.map { |item| sanitized_config(item) }
    when Hash
      sanitize_hash_config(value)
    when String
      value.match?(SENSITIVE_VALUE_PATTERN) ? '[REDACTED]' : value
    else
      value
    end
  end

  def sanitize_hash_config(value)
    value.each_with_object({}) do |(key, child), memo|
      memo[key] = sensitive_config_value?(key, child, value) ? '[REDACTED]' : sanitized_config(child)
    end
  end

  def sensitive_config_value?(key, child, parent)
    key.to_s.match?(SENSITIVE_KEY_PATTERN) ||
      child.to_s.match?(SENSITIVE_VALUE_PATTERN) ||
      (key.to_s == 'action_params' && parent['action_name'].to_s == 'send_webhook_event')
  end
end
