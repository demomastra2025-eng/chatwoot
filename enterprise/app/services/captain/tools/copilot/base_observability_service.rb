# frozen_string_literal: true

class Captain::Tools::Copilot::BaseObservabilityService < Captain::Tools::Copilot::BaseAccountTool
  DEFAULT_LOOKBACK = 24.hours
  MAX_LOOKBACK = 30.days
  OBSERVABILITY_LIMIT = 25
  OBSERVABILITY_MAX_LIMIT = 100
  SECRETISH_STRING_PATTERN = %r{(authorization|api[_-]?key|token|secret|password|cookie)\s*[:=]|bearer\s+[a-z0-9._~+/-]+=*}i

  def active?
    account_administrator?
  end

  private

  def time_range(since_value = nil, until_value = nil)
    until_time = parse_observability_time(until_value) || Time.current
    since_time = parse_observability_time(since_value) || (until_time - DEFAULT_LOOKBACK)
    since_time = until_time - MAX_LOOKBACK if since_time < until_time - MAX_LOOKBACK

    since_time..until_time
  end

  def parse_observability_time(value)
    return nil if value.blank?

    return Time.zone.at(value.to_i) if value.to_s.match?(/\A\d+\z/)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def observability_limit(value, default: OBSERVABILITY_LIMIT, max: OBSERVABILITY_MAX_LIMIT)
    parse_limit(value, default: default, max: max)
  end

  def observability_events(range:, params: {})
    Llm::Monitoring::EventsQuery.new(
      scope: account.llm_events,
      params: params,
      date_range: range
    )
  end

  def event_scope(range)
    account.llm_events.for_date_range(range)
  end

  def serialize_llm_event(event)
    {
      id: event.id,
      created_at: event.created_at&.iso8601,
      event_name: event.event_name,
      feature: event.feature,
      runtime_mode: event.runtime_mode,
      status: event.status,
      reason: event.reason,
      provider: event.provider,
      model: event.model,
      tool_name: event.tool_name,
      schema_name: event.schema_name,
      request_id: event.request_id,
      trace_id: event.trace_id.presence || event.payload['trace_id'],
      session_id: event.session_id,
      assistant_id: event.assistant_id,
      conversation_id: event.conversation_id,
      conversation_display_id: event.conversation_display_id,
      copilot_thread_id: event.copilot_thread_id,
      duration_ms: event.duration_ms,
      total_tokens: event.total_tokens,
      estimated_cost: event.estimated_cost,
      blocked: event.blocked,
      moderation_skipped: event.moderation_skipped,
      schema_invalid: event.schema_invalid,
      tool_failure: event.tool_failure,
      error: event.error,
      details: sanitized_payload(event.payload)
    }
  end

  def sanitized_payload(payload)
    redact_secretish_strings(Llm::Monitoring::PayloadSanitizer.call(payload || {}))
  end

  def redact_secretish_strings(value)
    case value
    when Hash
      value.transform_values { |child| redact_secretish_strings(child) }
    when Array
      value.map { |child| redact_secretish_strings(child) }
    when String
      secretish_string?(value) ? Llm::Monitoring::PayloadSanitizer::REDACTED : value
    else
      value
    end
  end

  def redact_error_string(value)
    return nil if value.blank?

    secretish_string?(value.to_s) ? Llm::Monitoring::PayloadSanitizer::REDACTED : value.to_s
  end

  def secretish_string?(value)
    value.to_s.match?(SECRETISH_STRING_PATTERN)
  end

  def health_status(error_count:, tool_failure_count:, failed_outgoing_count: 0)
    return 'unhealthy' if error_count.to_i >= 10 || failed_outgoing_count.to_i >= 10
    return 'degraded' if error_count.to_i.positive? || tool_failure_count.to_i.positive? || failed_outgoing_count.to_i.positive?

    'healthy'
  end

  def failed_outgoing_messages(range)
    account.messages.outgoing.failed.where(created_at: range)
  end

  def tool_execution_events(range)
    event_scope(range).for_event_name('llm.tool.complete')
  end

  def failed_tool_events(scope)
    scope.where('llm_events.error = ? OR llm_events.tool_failure = ? OR llm_events.status = ?', true, true, 'failed')
  end

  def serialize_tool_execution_event(event)
    details = sanitized_payload(event.payload || {}).with_indifferent_access

    {
      id: event.id,
      created_at: event.created_at&.iso8601,
      tool_id: event.tool_name,
      status: event.status,
      error: event.error,
      tool_failure: event.tool_failure,
      result_success: details[:result_success],
      result_retryable: details[:result_retryable],
      result_type: details[:result_type],
      result_size: details[:result_size],
      arguments_keys: details[:arguments_keys],
      arguments_size: details[:arguments_size],
      error_summary: safe_error_summary(details[:result_error_preview]),
      request_id: event.request_id,
      trace_id: event.trace_id.presence || event.payload['trace_id'],
      session_id: event.session_id,
      assistant_id: event.assistant_id,
      conversation_id: event.conversation_id,
      conversation_display_id: event.conversation_display_id,
      current_agent: event.current_agent,
      source: event.source
    }.compact
  end

  def external_error_for(message)
    redact_error_string(message.content_attributes&.dig('external_error') || message.content_attributes&.dig(:external_error))
  end

  def safe_error_summary(value)
    return if value.blank?

    redact_error_string(value).to_s.truncate(300)
  end
end
