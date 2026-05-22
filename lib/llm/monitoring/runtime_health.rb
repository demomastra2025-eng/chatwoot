# frozen_string_literal: true

class Llm::Monitoring::RuntimeHealth
  PROVIDER_FAILURE_ERROR_CODES = %w[
    provider_unavailable
    provider_timeout
    provider_rate_limited
    rate_limited
    timeout
    upstream_timeout
    upstream_error
    connection_failed
  ].freeze
  TOP_LIMIT = 10

  def initialize(account:, scope: LlmEvent.all, date_range: nil, now: Time.current, snapshot: nil, release_gate: nil)
    @account = account
    base_scope = scope.respond_to?(:except) ? scope.except(:order) : scope
    account_scope = @account.present? ? base_scope.for_account(@account.id) : base_scope
    @scope = account_scope.for_date_range(date_range)
    @date_range = date_range
    @now = now
    @snapshot = snapshot&.deep_symbolize_keys || Llm::Monitoring::MetricsSnapshot.new(scope: @scope).call
    @release_gate = release_gate.to_h.deep_symbolize_keys
  end

  def call
    checks = health_checks

    {
      status: overall_status(checks),
      account_id: @account&.id,
      evaluated_at: @now,
      date_range: date_range_payload,
      checks: checks,
      top_providers: top_counts(:provider),
      top_models: top_counts(:model),
      recent_error_codes: recent_error_codes
    }.compact
  end

  private

  def health_checks
    [
      event_ingestion_check,
      provider_failures_check,
      payload_budget_check,
      otel_event_export_check
    ]
  end

  def event_ingestion_check
    count = @snapshot[:total_events].to_i
    if count.positive?
      check(name: 'event_ingestion', status: 'pass', severity: 'info', actual: count, message: 'LLM events are being persisted for this window.')
    else
      check(name: 'event_ingestion', status: 'insufficient_data', severity: 'warning', actual: 0, message: 'No persisted LLM events in this window.')
    end
  end

  def provider_failures_check
    count = provider_failure_count
    if count.zero?
      return check(name: 'provider_failures', status: 'pass', severity: 'info', actual: 0,
                   message: 'No provider failure events in this window.')
    end

    check(
      name: 'provider_failures',
      status: 'fail',
      severity: 'critical',
      actual: count,
      message: 'Provider failure events were recorded in this window.'
    )
  end

  def payload_budget_check
    count = @snapshot[:payload_truncated_count].to_i
    if count.zero?
      return check(name: 'payload_budget', status: 'pass', severity: 'info', actual: 0,
                   message: 'Persisted LLM event payloads stayed within the budget.')
    end

    check(
      name: 'payload_budget',
      status: 'warn',
      severity: 'warning',
      actual: count,
      message: 'Some LLM event payload summaries were truncated to stay within the persistence budget.'
    )
  end

  def otel_event_export_check
    state = otel_event_export_state
    if state[:status] == 'enabled'
      return check(name: 'otel_event_export', status: 'pass', severity: 'info', actual: state,
                   message: 'EventBus OTel export is enabled and sample rate is valid.')
    end
    if state[:status] == 'disabled'
      return check(name: 'otel_event_export', status: 'disabled', severity: 'info', actual: state,
                   message: 'EventBus OTel export is disabled.')
    end

    check(
      name: 'otel_event_export',
      status: 'warn',
      severity: 'warning',
      actual: state,
      message: 'EventBus OTel export is configured but will fail closed until the sample-rate configuration is fixed.'
    )
  end

  def check(name:, status:, severity:, actual:, message:)
    {
      name: name,
      status: status,
      severity: severity,
      actual: actual,
      message: message
    }
  end

  def overall_status(checks)
    return 'insufficient_data' if checks.first[:status] == 'insufficient_data'
    return 'critical' if checks.any? { |check| check[:severity] == 'critical' && check[:status] == 'fail' }
    return 'warning' if checks.any? { |check| check[:severity] == 'warning' && %w[warn fail].include?(check[:status]) }

    release_gate_status = @release_gate[:status].to_s
    return 'critical' if release_gate_status == 'fail'
    return 'insufficient_data' if release_gate_status == 'insufficient_data'

    'ok'
  end

  def provider_failure_count
    @provider_failure_count ||= @scope.where(error_code: PROVIDER_FAILURE_ERROR_CODES).count
  end

  def top_counts(column)
    @scope.where.not(column => nil).group(column).count.sort_by { |name, count| [-count, name.to_s] }.first(TOP_LIMIT).to_h
  end

  def recent_error_codes
    @scope.error_events.where.not(error_code: nil).group(:error_code).count.sort_by { |code, count| [-count, code.to_s] }.first(TOP_LIMIT).to_h
  end

  def otel_event_export_state
    product_otel_enabled = ChatwootApp.otel_enabled?
    export_enabled = ActiveModel::Type::Boolean.new.cast(otel_export_enabled_value)
    sample_rate, sample_valid = sample_rate_payload
    status = if export_enabled && product_otel_enabled && !sample_valid
               'misconfigured'
             elsif export_enabled && product_otel_enabled && sample_rate.to_f.positive?
               'enabled'
             else
               'disabled'
             end

    {
      status: status,
      product_otel_enabled: product_otel_enabled,
      event_export_enabled: export_enabled,
      sample_rate: sample_rate,
      sample_rate_valid: sample_valid
    }
  rescue StandardError
    {
      status: 'disabled',
      product_otel_enabled: false,
      event_export_enabled: false,
      sample_rate: nil,
      sample_rate_valid: false
    }
  end

  def otel_export_enabled_value
    ENV.fetch(Llm::Monitoring::OtelEventExporter::ENV_ENABLED_KEY, nil).presence ||
      InstallationConfig.find_by(name: Llm::Monitoring::OtelEventExporter::CONFIG_ENABLED_KEY)&.value
  rescue StandardError
    nil
  end

  def sample_rate_payload
    value = ENV.fetch(Llm::Monitoring::OtelEventExporter::ENV_SAMPLE_RATE_KEY, nil).presence
    return [Llm::Monitoring::OtelEventExporter::DEFAULT_SAMPLE_RATE, true] if value.blank?

    [Float(value).clamp(0.0, 1.0), true]
  rescue ArgumentError, TypeError
    [nil, false]
  end

  def date_range_payload
    return if @date_range.blank?

    {
      started_at: @date_range.begin,
      ended_at: @date_range.end
    }
  end
end
