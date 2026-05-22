# frozen_string_literal: true

class Llm::Monitoring::PrometheusExporter
  RELEASE_GATE_STATUSES = %w[pass fail insufficient_data disabled].freeze

  def initialize(snapshot:, release_gate:, labels: {}, alerts: nil)
    @snapshot = snapshot.to_h
    @release_gate = release_gate.to_h
    @alerts = alerts.to_h.deep_symbolize_keys
    @base_labels = labels.to_h.compact.stringify_keys
  end

  def call
    lines = []
    append_counter(lines, 'llm_events_total', 'Persisted LLM events.', @snapshot[:total_events])
    append_counter(lines, 'llm_requests_total', 'LLM chat completion requests.', @snapshot[:request_count])
    append_counter(lines, 'llm_embeddings_total', 'LLM embedding requests.', @snapshot[:embedding_count])
    append_counter(lines, 'llm_transcriptions_total', 'LLM audio transcription requests.', @snapshot[:transcription_count])
    append_counter(lines, 'llm_moderation_checks_total', 'LLM moderation checks.', @snapshot[:moderation_count])
    append_counter(lines, 'llm_safety_blocked_total', 'LLM events blocked by safety policy.', @snapshot[:blocked_count])
    append_counter(lines, 'llm_errors_total', 'LLM events recorded as errors.', @snapshot[:error_count])
    append_counter(lines, 'llm_provider_failures_total', 'LLM events recorded with provider failure error codes.', @snapshot[:provider_failure_count])
    append_counter(lines, 'llm_moderation_skipped_total', 'LLM moderation checks skipped because safety was unavailable.',
                   @snapshot[:moderation_skipped_count])
    append_counter(lines, 'llm_schema_invalid_total', 'Invalid structured-output responses.', @snapshot[:schema_invalid_count])
    append_counter(lines, 'llm_tool_failures_total', 'Tool executions recorded as failures.', @snapshot[:tool_failure_count])
    append_counter(lines, 'llm_tokens_total', 'LLM tokens used by chat completions.', @snapshot[:total_tokens])
    append_counter(lines, 'llm_all_tokens_total', 'LLM tokens used by all persisted AI events.', @snapshot[:all_total_tokens])
    append_counter(lines, 'llm_estimated_cost_usd_total', 'Estimated LLM cost in USD.', @snapshot[:estimated_cost])
    append_counter(lines, 'llm_all_estimated_cost_usd_total', 'Estimated LLM cost in USD across all persisted AI events.',
                   @snapshot[:total_estimated_cost])
    append_gauge(lines, 'llm_request_duration_ms_average', 'Average LLM chat completion duration in milliseconds.', @snapshot[:avg_duration_ms])
    append_gauge(lines, 'llm_last_event_timestamp_seconds', 'Unix timestamp for the last persisted LLM event.', last_event_timestamp)

    append_grouped_counters(lines, 'llm_requests_by_feature_total', 'LLM chat completion requests by feature.', @snapshot[:by_feature], :feature)
    append_grouped_counters(lines, 'llm_requests_by_model_total', 'LLM chat completion requests by model.', @snapshot[:by_model], :model)
    append_grouped_counters(lines, 'llm_requests_by_provider_total', 'LLM chat completion requests by provider.', @snapshot[:by_provider], :provider)
    append_grouped_counters(lines, 'llm_events_by_name_total', 'Persisted LLM events by event name.', @snapshot[:by_event_name], :event_name)
    append_grouped_counters(lines, 'llm_events_by_status_total', 'Persisted LLM events by status.', @snapshot[:by_status], :status)
    append_release_gate(lines)
    append_alerts(lines)

    "#{lines.join("\n")}\n"
  end

  private

  def append_counter(lines, metric_name, help, value, labels = {})
    append_metric(lines, metric_name, help, 'counter', value, labels)
  end

  def append_gauge(lines, metric_name, help, value, labels = {})
    append_metric(lines, metric_name, help, 'gauge', value, labels)
  end

  def append_metric(lines, metric_name, help, type, value, labels)
    return if value.nil?

    lines << "# HELP #{metric_name} #{help}"
    lines << "# TYPE #{metric_name} #{type}"
    lines << "#{metric_name}#{format_labels(labels)} #{format_value(value)}"
  end

  def append_grouped_counters(lines, metric_name, help, grouped_values, label_name)
    grouped_values = grouped_values.to_h.compact
    return if grouped_values.blank?

    lines << "# HELP #{metric_name} #{help}"
    lines << "# TYPE #{metric_name} counter"
    grouped_values.each do |label_value, count|
      lines << "#{metric_name}#{format_labels(label_name => label_value)} #{format_value(count)}"
    end
  end

  def append_release_gate(lines)
    lines << '# HELP llm_release_gate_status Current release gate status. Exactly one status label should be 1.'
    lines << '# TYPE llm_release_gate_status gauge'

    status = @release_gate[:status].to_s.presence || 'insufficient_data'
    RELEASE_GATE_STATUSES.each do |candidate|
      lines << "llm_release_gate_status#{format_labels(status: candidate)} #{candidate == status ? 1 : 0}"
    end
  end

  def append_alerts(lines)
    append_gauge(lines, 'llm_alerts_active_total', 'Active AI operational alerts derived from the release gate.', @alerts[:active_count])

    alerts = Array(@alerts[:alerts])
    return if alerts.blank?

    lines << '# HELP llm_alert_active Active AI operational alert by alert name and severity.'
    lines << '# TYPE llm_alert_active gauge'

    alerts.each do |alert|
      lines << "llm_alert_active#{format_labels(alert: alert[:name], severity: alert[:severity])} 1"
    end
  end

  def format_labels(labels)
    merged = @base_labels.merge(labels.to_h.stringify_keys).compact_blank
    return '' if merged.blank?

    formatted = merged.map do |key, value|
      %(#{key}="#{escape_label_value(value)}")
    end.join(',')

    "{#{formatted}}"
  end

  def escape_label_value(value)
    value.to_s.gsub('\\', '\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
  end

  def format_value(value)
    case value
    when Time
      value.to_i
    when BigDecimal
      value.to_s('F')
    else
      value
    end
  end

  def last_event_timestamp
    @snapshot[:last_event_at]&.to_i
  end
end
