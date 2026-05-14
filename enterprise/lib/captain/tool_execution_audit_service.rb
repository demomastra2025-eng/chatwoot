class Captain::ToolExecutionAuditService
  MAX_RESULT_PREVIEW_LENGTH = 1000
  SENSITIVE_KEY_PATTERN = /(otp|token|secret|password|credential|authorization|process_?id|session)/i

  class << self
    def record(...)
      new(...).record
    end
  end

  def initialize(assistant:, scope_name:, tool_definition:, arguments:, result: nil, error: nil, user: nil, runtime_context: {})
    @assistant = assistant
    @scope_name = scope_name
    @tool_definition = (tool_definition || {}).with_indifferent_access
    @arguments = arguments
    @result = result
    @error = error
    @user = user
    @runtime_context = (runtime_context || {}).with_indifferent_access
  end

  def record
    return if assistant.blank?
    return unless assistant.account.feature_enabled?(:audit_logs)

    Enterprise::AuditLog.create(
      auditable: assistant,
      associated: assistant.account,
      user: user,
      action: 'captain_tool_execute',
      comment: "Captain tool execution: #{tool_id}",
      audited_changes: payload
    )
  rescue StandardError => e
    Rails.logger.warn do
      "#{self.class.name} failed for assistant #{assistant&.id}: #{e.class} - #{e.message}"
    end
  end

  private

  attr_reader :assistant, :scope_name, :user, :error

  def payload
    normalized_result = Captain::ToolResult.normalize(@result, error: error)

    {
      scope: scope_name,
      tool_id: tool_id,
      tool_title: @tool_definition[:title],
      custom: ActiveModel::Type::Boolean.new.cast(@tool_definition[:custom]),
      risk_level: @tool_definition[:risk_level],
      requires_confirmation: ActiveModel::Type::Boolean.new.cast(@tool_definition[:requires_confirmation]),
      arguments: serializable_value(@arguments),
      result_preview: serialized_preview(@result),
      result_success: normalized_result[:success],
      result_message: normalized_result[:message],
      result_error: normalized_result[:error],
      result_retryable: normalized_result[:retryable],
      result_data_preview: serialized_preview(normalized_result[:data]),
      result_audit: serializable_value(normalized_result[:audit]),
      error_class: error&.class&.name,
      error_message: error&.message,
      conversation_id: @runtime_context[:conversation_id],
      conversation_display_id: @runtime_context[:conversation_display_id],
      source: @runtime_context[:source],
      current_agent: @runtime_context[:current_agent]
    }.compact
  end

  def tool_id
    @tool_definition[:id].presence || 'unknown_tool'
  end

  def serializable_value(value)
    serializable = value.respond_to?(:as_json) ? value.as_json : value

    Captain::EncodingNormalizer.utf8(redact_sensitive(serializable))
  rescue StandardError
    Captain::EncodingNormalizer.string(value.to_s)
  end

  def serialized_preview(value)
    return if value.nil?

    preview =
      case value
      when String
        redacted_string_preview(value)
      else
        JSON.generate(serializable_value(value))
      end

    preview.truncate(MAX_RESULT_PREVIEW_LENGTH)
  rescue StandardError
    value.to_s.truncate(MAX_RESULT_PREVIEW_LENGTH)
  end

  def redacted_string_preview(value)
    parsed = JSON.parse(value)
    JSON.generate(redact_sensitive(parsed))
  rescue JSON::ParserError
    Captain::EncodingNormalizer.string(value)
  end

  def redact_sensitive(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), redacted|
        redacted[key] = sensitive_key?(key) ? '[FILTERED]' : redact_sensitive(item)
      end
    when Array
      value.map { |item| redact_sensitive(item) }
    else
      value
    end
  end

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end
end
