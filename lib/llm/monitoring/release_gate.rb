# frozen_string_literal: true

class Llm::Monitoring::ReleaseGate
  DEFAULT_WINDOW = 7.days
  REQUEST_ANCHOR_EVENTS = %w[
    llm.chat.complete
    llm.embedding.complete
    llm.run.complete
    llm.safety.blocked
    llm.transcription.complete
  ].freeze
  DEFAULT_CONFIG = {
    enabled: true,
    min_request_count: 10,
    max_error_rate: 0.05,
    max_schema_invalid_rate: 0.02,
    max_tool_failure_rate: 0.10,
    max_moderation_skipped_rate: 0.0,
    max_avg_duration_ms: 15_000,
    max_p95_duration_ms: 30_000,
    max_cost_per_request: 0.05,
    max_error_rate_regression: 2.0,
    max_avg_duration_regression: 1.5
  }.freeze

  def initialize(scope: LlmEvent.all, date_range: nil, config: {}, now: Time.current)
    @scope = scope.respond_to?(:except) ? scope.except(:order) : scope
    @config = DEFAULT_CONFIG.merge(config.to_h.symbolize_keys).freeze
    @now = now
    @date_range = normalize_date_range(date_range)
  end

  def call
    return disabled_payload unless @config[:enabled]

    current_metrics = metrics_for(current_scope)
    baseline_metrics = metrics_for(baseline_scope)
    checks = build_checks(current_metrics, baseline_metrics)

    {
      status: overall_status(current_metrics, checks),
      evaluated_at: @now,
      config: @config,
      current_period: period_payload(@date_range, current_metrics),
      baseline_period: period_payload(baseline_date_range, baseline_metrics),
      checks: checks
    }
  end

  private

  def disabled_payload
    {
      status: 'disabled',
      evaluated_at: @now,
      config: @config,
      current_period: period_payload(@date_range, metrics_for(current_scope)),
      baseline_period: period_payload(baseline_date_range, metrics_for(baseline_scope)),
      checks: []
    }
  end

  def overall_status(current_metrics, checks)
    return 'insufficient_data' if current_metrics[:request_count] < @config[:min_request_count].to_i
    return 'fail' if checks.any? { |check| check[:status] == 'fail' }

    'pass'
  end

  def current_scope
    @scope.where(created_at: @date_range)
  end

  def baseline_scope
    @scope.where(created_at: baseline_date_range)
  end

  def baseline_date_range
    @baseline_date_range ||= begin
      duration = @date_range.end - @date_range.begin
      start_time = @date_range.begin - duration
      end_time = @date_range.begin
      start_time..end_time
    end
  end

  def normalize_date_range(date_range)
    return default_date_range if date_range.blank?

    date_range.begin..date_range.end
  end

  def default_date_range
    (@now - DEFAULT_WINDOW)..@now
  end

  def metrics_for(scope)
    snapshot = Llm::Monitoring::MetricsSnapshot.new(scope: scope).call
    request_rollups = build_request_rollups(scope)
    request_count = request_rollups.size
    durations = request_rollups.filter_map { |rollup| rollup[:duration_ms] }.sort
    cost = request_rollups.sum { |rollup| rollup[:estimated_cost] }
    error_request_count = request_rollups.count { |rollup| rollup[:error] }
    blocked_request_count = request_rollups.count { |rollup| rollup[:blocked] }
    schema_invalid_request_count = request_rollups.count { |rollup| rollup[:schema_invalid] }
    tool_failure_request_count = request_rollups.count { |rollup| rollup[:tool_failure] }
    moderation_skipped_request_count = request_rollups.count { |rollup| rollup[:moderation_skipped] }

    snapshot.merge(
      request_count: request_count,
      error_rate: rate(error_request_count, request_count),
      schema_invalid_rate: rate(schema_invalid_request_count, request_count),
      tool_failure_rate: rate(tool_failure_request_count, request_count),
      moderation_skipped_rate: rate(moderation_skipped_request_count, request_count),
      blocked_rate: rate(blocked_request_count, request_count),
      cost_per_request: request_count.positive? ? (cost / request_count) : 0.to_d,
      p95_duration_ms: percentile(durations, 0.95)
    )
  end

  def build_request_rollups(scope)
    scope
      .select(
        :id,
        :event_name,
        :request_id,
        :trace_id,
        :session_id,
        :blocked,
        :error,
        :schema_invalid,
        :tool_failure,
        :moderation_skipped,
        :estimated_cost,
        :duration_ms
      )
      .each_with_object({}) do |event, rollups|
        request_key = request_rollup_key(event)
        next if request_key.blank?

        rollup = rollups[request_key] ||= {
          blocked: false,
          error: false,
          schema_invalid: false,
          tool_failure: false,
          moderation_skipped: false,
          estimated_cost: 0.to_d,
          duration_ms: nil
        }

        rollup[:blocked] ||= event.blocked?
        rollup[:error] ||= event.error?
        rollup[:schema_invalid] ||= event.schema_invalid?
        rollup[:tool_failure] ||= event.tool_failure?
        rollup[:moderation_skipped] ||= event.moderation_skipped?
        rollup[:estimated_cost] += event.estimated_cost.to_d if event.estimated_cost.present?
        rollup[:duration_ms] = [rollup[:duration_ms].to_i, event.duration_ms.to_i].max if event.duration_ms.present?
      end.values
  end

  def request_rollup_key(event)
    return "request:#{event.request_id}" if event.request_id.present?
    return "trace:#{event.trace_id}" if event.trace_id.present?
    return "event:#{event.id}" if REQUEST_ANCHOR_EVENTS.include?(event.event_name)

    nil
  end

  def period_payload(range, metrics)
    {
      started_at: range.begin,
      ended_at: range.end,
      metrics: metrics
    }
  end

  def build_checks(current_metrics, baseline_metrics)
    [
      threshold_check(
        name: 'error_rate',
        actual: current_metrics[:error_rate],
        expected: @config[:max_error_rate],
        comparator: :<=,
        message: 'Error event rate exceeds the allowed threshold.'
      ),
      threshold_check(
        name: 'schema_invalid_rate',
        actual: current_metrics[:schema_invalid_rate],
        expected: @config[:max_schema_invalid_rate],
        comparator: :<=,
        message: 'Structured output invalidation rate exceeds the allowed threshold.'
      ),
      threshold_check(
        name: 'tool_failure_rate',
        actual: current_metrics[:tool_failure_rate],
        expected: @config[:max_tool_failure_rate],
        comparator: :<=,
        message: 'Tool failure rate exceeds the allowed threshold.'
      ),
      threshold_check(
        name: 'moderation_skipped_rate',
        actual: current_metrics[:moderation_skipped_rate],
        expected: @config[:max_moderation_skipped_rate],
        comparator: :<=,
        message: 'Moderation is being skipped above the allowed threshold.'
      ),
      threshold_check(
        name: 'avg_duration_ms',
        actual: current_metrics[:avg_duration_ms],
        expected: @config[:max_avg_duration_ms],
        comparator: :<=,
        message: 'Average request latency exceeds the allowed threshold.'
      ),
      threshold_check(
        name: 'p95_duration_ms',
        actual: current_metrics[:p95_duration_ms],
        expected: @config[:max_p95_duration_ms],
        comparator: :<=,
        message: 'P95 request latency exceeds the allowed threshold.'
      ),
      threshold_check(
        name: 'cost_per_request',
        actual: current_metrics[:cost_per_request],
        expected: @config[:max_cost_per_request],
        comparator: :<=,
        message: 'Average request cost exceeds the allowed threshold.'
      ),
      regression_check(
        name: 'error_rate_regression',
        current_value: current_metrics[:error_rate],
        baseline_value: baseline_metrics[:error_rate],
        max_factor: @config[:max_error_rate_regression],
        message: 'Error rate regressed too sharply against the previous period.'
      ),
      regression_check(
        name: 'avg_duration_regression',
        current_value: current_metrics[:avg_duration_ms],
        baseline_value: baseline_metrics[:avg_duration_ms],
        max_factor: @config[:max_avg_duration_regression],
        message: 'Average latency regressed too sharply against the previous period.'
      )
    ]
  end

  def threshold_check(name:, actual:, expected:, comparator:, message:)
    return skipped_check(name, message: 'Not enough data to evaluate this threshold.') if actual.nil?

    passed = actual.public_send(comparator, expected)

    {
      name: name,
      status: passed ? 'pass' : 'fail',
      actual: actual,
      expected: expected,
      message: passed ? nil : message
    }.compact
  end

  def regression_check(name:, current_value:, baseline_value:, max_factor:, message:)
    return skipped_check(name, message: 'Baseline window has no comparable data.') if current_value.nil? || baseline_value.nil?
    return skipped_check(name, message: 'Baseline value is zero, absolute threshold already applies.') if baseline_value.to_f.zero?

    factor = current_value.to_f / baseline_value.to_f
    passed = factor <= max_factor.to_f

    {
      name: name,
      status: passed ? 'pass' : 'fail',
      actual: factor,
      expected: max_factor,
      message: passed ? nil : message
    }.compact
  end

  def skipped_check(name, message:)
    {
      name: name,
      status: 'not_applicable',
      message: message
    }
  end

  def percentile(values, percentile)
    return if values.blank?

    index = ((values.length - 1) * percentile).ceil
    values[index]
  end

  def rate(numerator, denominator)
    return 0.0 if denominator.to_i <= 0

    numerator.to_f / denominator.to_f
  end
end
