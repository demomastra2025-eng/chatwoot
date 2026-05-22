# frozen_string_literal: true

class Llm::Monitoring::AlertEvaluator
  SEVERITY_BY_CHECK = {
    error_rate: 'critical',
    provider_failure_rate: 'critical',
    payload_truncated_rate: 'warning',
    moderation_skipped_rate: 'critical',
    schema_invalid_rate: 'warning',
    tool_failure_rate: 'warning',
    avg_duration_ms: 'warning',
    p95_duration_ms: 'warning',
    cost_per_request: 'warning',
    error_rate_regression: 'warning',
    avg_duration_regression: 'warning'
  }.freeze

  def initialize(release_gate_report:)
    @release_gate_report = release_gate_report.to_h.deep_symbolize_keys
  end

  def call
    release_gate_status = @release_gate_report[:status].to_s.presence || 'insufficient_data'
    active_alerts = actionable_release_gate_status?(release_gate_status) ? failed_checks.map { |check| alert_for(check) } : []

    {
      status: alert_status(release_gate_status, active_alerts),
      release_gate_status: release_gate_status,
      evaluated_at: @release_gate_report[:evaluated_at],
      active_count: active_alerts.size,
      alerts: active_alerts
    }
  end

  private

  def failed_checks
    Array(@release_gate_report[:checks]).select { |check| check[:status].to_s == 'fail' }
  end

  def alert_for(check)
    {
      name: check[:name],
      severity: SEVERITY_BY_CHECK.fetch(check[:name].to_s.to_sym, 'warning'),
      status: 'firing',
      actual: check[:actual],
      expected: check[:expected],
      message: check[:message]
    }.compact
  end

  def alert_status(release_gate_status, active_alerts)
    return 'disabled' if release_gate_status == 'disabled'
    return 'insufficient_data' if release_gate_status == 'insufficient_data'

    active_alerts.any? ? 'alerting' : 'ok'
  end

  def actionable_release_gate_status?(release_gate_status)
    !%w[disabled insufficient_data].include?(release_gate_status)
  end
end
