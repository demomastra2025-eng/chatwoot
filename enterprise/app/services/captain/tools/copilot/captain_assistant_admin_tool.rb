# frozen_string_literal: true

class Captain::Tools::Copilot::CaptainAssistantAdminTool < Captain::Tools::Copilot::BaseAccountTool
  CONFIG_FIELD_KEYS = %w[
    feature_faq feature_memory feature_citation welcome_message handoff_message resolution_message
    handoff_message_enabled handoff_message_mode resolution_message_enabled resolution_message_mode
    temperature auto_reply_on_last_incoming message_collapse_window_seconds history_message_limit
    context_access tool_access voice_settings rules
  ].freeze
  SENSITIVE_KEY_PATTERN = /(otp|token|secret|password|credential|authorization|process_?id|session|api_?key|access_?key|refresh|url|webhook)/i
  SENSITIVE_VALUE_PATTERN = %r{
    https?://|
    bearer\s+|
    authorization\s*[:=]|
    (?:token|api[_\s-]?key|secret|password|credential|session|webhook)\s*[:=]
  }ix

  def active?
    account_administrator?
  end

  private

  def find_captain_assistant!(assistant_id)
    account.captain_assistants.find(assistant_id)
  end

  def assistant_payload(assistant, include_config: false)
    base_assistant_payload(assistant).tap do |payload|
      merge_extended_assistant_payload!(payload, assistant) if include_config
    end
  end

  def base_assistant_payload(assistant)
    assistant_identity_payload(assistant)
      .merge(assistant_config_summary_payload(assistant))
      .merge(assistant_access_summary_payload(assistant))
      .merge(assistant_timestamp_payload(assistant))
  end

  def assistant_identity_payload(assistant)
    {
      id: assistant.id,
      name: assistant.name,
      description: assistant.description,
      usage_mode: assistant.usage_mode
    }
  end

  def assistant_config_summary_payload(assistant)
    {
      feature_faq: cast_config_boolean(assistant.config&.dig('feature_faq')),
      feature_memory: cast_config_boolean(assistant.config&.dig('feature_memory')),
      feature_citation: cast_config_boolean(assistant.config&.dig('feature_citation')),
      temperature: assistant.config&.dig('temperature')
    }
  end

  def assistant_access_summary_payload(assistant)
    {
      selected_agent_tool_ids: assistant.selected_agent_tool_ids,
      selected_assistant_tool_ids: assistant.selected_assistant_tool_ids,
      selected_context_field_ids: assistant.selected_context_field_ids,
      scenarios_count: assistant.scenarios.count,
      connected_inboxes_count: assistant.captain_inboxes.count
    }
  end

  def assistant_timestamp_payload(assistant)
    {
      created_at: assistant.created_at&.iso8601,
      updated_at: assistant.updated_at&.iso8601
    }
  end

  def merge_extended_assistant_payload!(payload, assistant)
    payload[:config] = redacted_value(assistant.config)
    payload[:response_guidelines] = redacted_value(assistant.response_guidelines)
    payload[:guardrails] = redacted_value(assistant.guardrails)
  end

  def parse_json_hash(value, field_name:, default: {})
    return default if value.nil?
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def parse_json_array(value, field_name:, default: nil)
    return default if value.nil?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON array" unless parsed.is_a?(Array)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def filtered_config_updates(value)
    parse_json_hash(value, field_name: 'config_json').deep_stringify_keys.slice(*CONFIG_FIELD_KEYS)
  end

  def cast_config_boolean(value)
    return nil if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def redacted_value(value)
    return redacted_hash(value) if value.is_a?(Hash)
    return value.map { |item| redacted_value(item) } if value.is_a?(Array)
    return '[FILTERED]' if sensitive_string?(value)

    value
  end

  def redacted_hash(value)
    value.each_with_object({}) do |(key, item), result|
      result[key] = sensitive_key?(key) ? '[FILTERED]' : redacted_value(item)
    end
  end

  def sensitive_string?(value)
    value.is_a?(String) && value.match?(SENSITIVE_VALUE_PATTERN)
  end

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end
end
