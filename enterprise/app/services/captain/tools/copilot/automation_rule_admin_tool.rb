# frozen_string_literal: true

class Captain::Tools::Copilot::AutomationRuleAdminTool < Captain::Tools::Copilot::BaseAccountTool
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|auth|api[_-]?key|access[_-]?key|url|webhook/i
  SENSITIVE_VALUE_PATTERN = %r{https?://|bearer\s+|token=|api[_-]?key=|secret=}i

  def active?
    account_administrator?
  end

  private

  def automation_rule!(automation_rule_id)
    account.automation_rules.find(automation_rule_id)
  end

  def automation_rule_payload(rule, include_config: true)
    payload = automation_rule_base_payload(rule)
    payload.merge!(automation_rule_config_payload(rule)) if include_config
    payload
  end

  def automation_rule_base_payload(rule)
    {
      id: rule.id,
      name: rule.name,
      description: rule.description,
      event_name: rule.event_name,
      active: rule.active,
      conditions_count: Array.wrap(rule.conditions).size,
      actions_count: Array.wrap(rule.actions).size,
      action_names: Array.wrap(rule.actions).filter_map { |action| action['action_name'] || action[:action_name] },
      created_at: rule.created_at&.iso8601,
      updated_at: rule.updated_at&.iso8601
    }.compact
  end

  def automation_rule_config_payload(rule)
    {
      conditions: sanitized_config(rule.conditions),
      actions: sanitized_config(rule.actions)
    }
  end

  def parse_json_array(value, field_name:, default: [])
    return default if value.nil?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON array" unless parsed.is_a?(Array)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def build_rule_attributes(name: nil, description: nil, event_name: nil, active: nil)
    attrs = {}
    attrs[:name] = name if name.present?
    attrs[:description] = description unless description.nil?
    attrs[:event_name] = event_name if event_name.present?
    attrs[:active] = cast_boolean(active) unless active.nil?
    attrs
  end

  def save_rule!(rule)
    rule.save!
    rule
  rescue ActiveRecord::RecordInvalid
    raise ArgumentError, rule.errors.full_messages.join(', ')
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
