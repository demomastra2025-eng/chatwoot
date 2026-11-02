# frozen_string_literal: true

class Captain::Tools::Account::CaptainAssistantAdminTool < Captain::Tools::Account::BaseAccountTool
  CONFIG_FIELD_KEYS = %w[
    context_access tool_access capabilities voice_settings
  ].freeze
  SENSITIVE_KEY_PATTERN = /(otp|token|secret|password|credential|authorization|process_?id|session|api_?key|access_?key|refresh|url|webhook)/i
  SENSITIVE_VALUE_PATTERN = %r{
    https?://[^\s"']*(?:webhook|token|secret|api[_-]?key|password|credential|callback)|
    bearer\s+|
    authorization\s*[:=]|
    (?:token|api[_\s-]?key|secret|password|credential|session|webhook)\s*[:=]
  }ix

  def active?
    account_administrator?
  end

  private

  def tool_failure(error, retryable: nil)
    if error.is_a?(Captain::AssistantConfigContract::Violation)
      return Captain::ToolResult.failure(error: error.code, data: { error: error.code, fields: error.fields }, retryable: false)
    end

    super
  end

  def ensure_platform_prompt_access!(field)
    return if Captain::PromptInspectorAccess.allowed?(user: @user)

    raise Captain::AssistantConfigContract::Violation.new('platform_managed_prompt', [field])
  end

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
    redacted_value(Captain::AssistantSerializer.new(assistant, user: @user).profile)
  end

  def assistant_config_summary_payload(assistant)
    {
      feature_faq: assistant.feature_faq,
      feature_memory: false,
      effective_settings: Captain::AssistantConfigContract.effective_settings(assistant)
    }
  end

  def assistant_access_summary_payload(assistant)
    {
      selected_agent_tool_ids: assistant.selected_agent_tool_ids,
      selected_assistant_tool_ids: assistant.selected_assistant_tool_ids,
      selected_context_field_ids: assistant.selected_context_field_ids,
      scenarios_count: assistant.scenarios.count,
      voice_inboxes_count: assistant.captain_inboxes.count
    }
  end

  def assistant_timestamp_payload(assistant)
    {
      created_at: assistant.created_at&.iso8601,
      updated_at: assistant.updated_at&.iso8601
    }
  end

  def merge_extended_assistant_payload!(payload, assistant)
    payload[:config] = redacted_value(Captain::AssistantSerializer.new(assistant, user: @user).config)
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
    config = parse_json_hash(value, field_name: 'config_json').deep_stringify_keys
    raise ArgumentError, 'Separate rules were removed. Save instructions in description.' if config.key?('rules')

    violation = Captain::AssistantConfigContract.write_violation({ config: config }, platform: Captain::PromptInspectorAccess.allowed?(user: @user))
    raise Captain::AssistantConfigContract::Violation.new(violation[:error], violation[:fields]) if violation

    unsupported = config.keys - CONFIG_FIELD_KEYS
    if unsupported.any?
      raise Captain::AssistantConfigContract::Violation.new('unsupported_assistant_settings', unsupported.map { |field| "config.#{field}" })
    end

    config.slice(*CONFIG_FIELD_KEYS)
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
