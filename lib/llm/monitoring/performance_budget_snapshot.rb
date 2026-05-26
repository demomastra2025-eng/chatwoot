# frozen_string_literal: true

class Llm::Monitoring::PerformanceBudgetSnapshot
  DEFAULT_LIMIT = 20
  DEFAULT_BUDGETS = {
    max_p95_duration_ms: 8_000,
    max_p95_queue_wait_ms: 2_000,
    max_p95_payload_bytes: 32.kilobytes,
    max_p95_total_tokens: 12_000,
    max_cost_per_request: 0.05,
    max_error_rate: 0.05
  }.freeze
  CHECKS = [
    { name: 'p95_duration_ms', metric: :p95_duration_ms, budget: :max_p95_duration_ms },
    { name: 'p95_queue_wait_ms', metric: :p95_queue_wait_ms, budget: :max_p95_queue_wait_ms },
    { name: 'p95_payload_bytes', metric: :p95_payload_bytes, budget: :max_p95_payload_bytes },
    { name: 'p95_total_tokens', metric: :p95_total_tokens, budget: :max_p95_total_tokens },
    { name: 'avg_cost_per_request', metric: :avg_cost_per_request, budget: :max_cost_per_request },
    { name: 'request_error_rate', metric: :request_error_rate, budget: :max_error_rate }
  ].freeze
  TOP_CASES_SELECT = <<~SQL.squish.freeze
    project_case_id,
    COUNT(*) AS event_count,
    COUNT(*) FILTER (WHERE event_name = 'llm.chat.complete') AS request_count,
    COUNT(*) FILTER (WHERE error = TRUE) AS event_error_count,
    COUNT(*) FILTER (WHERE event_name = 'llm.chat.complete' AND error = TRUE) AS request_error_count,
    AVG(duration_ms) FILTER (WHERE event_name = 'llm.chat.complete' AND duration_ms IS NOT NULL) AS avg_duration_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
      FILTER (WHERE event_name = 'llm.chat.complete' AND duration_ms IS NOT NULL) AS p95_duration_ms,
    percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms)
      FILTER (WHERE event_name = 'llm.chat.complete' AND duration_ms IS NOT NULL) AS p99_duration_ms,
    AVG(queue_wait_ms) FILTER (WHERE queue_wait_ms IS NOT NULL) AS avg_queue_wait_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY queue_wait_ms)
      FILTER (WHERE queue_wait_ms IS NOT NULL) AS p95_queue_wait_ms,
    AVG(payload_bytes) FILTER (WHERE payload_bytes IS NOT NULL) AS avg_payload_bytes,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY payload_bytes)
      FILTER (WHERE payload_bytes IS NOT NULL) AS p95_payload_bytes,
    MAX(payload_bytes) AS max_payload_bytes,
    AVG(total_tokens) FILTER (WHERE event_name = 'llm.chat.complete' AND total_tokens IS NOT NULL) AS avg_total_tokens,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY total_tokens)
      FILTER (WHERE event_name = 'llm.chat.complete' AND total_tokens IS NOT NULL) AS p95_total_tokens,
    SUM(estimated_cost) AS total_estimated_cost,
    SUM(estimated_cost) FILTER (WHERE event_name = 'llm.chat.complete') AS request_estimated_cost,
    COUNT(*) FILTER (WHERE payload_truncated = TRUE) AS payload_truncated_count,
    SUM(COALESCE(retry_count, 0)) AS retry_occurrences,
    SUM(COALESCE(tool_calls_count, 0)) AS tool_call_occurrences
  SQL

  def initialize(scope: LlmEvent.all, budgets: {}, limit: DEFAULT_LIMIT)
    @scope = scope.respond_to?(:except) ? scope.except(:order) : scope
    @budgets = DEFAULT_BUDGETS.merge(budgets.to_h.symbolize_keys).compact
    @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
  end

  def call
    cases = top_case_rows.map { |row| build_case_snapshot(row) }

    {
      generated_at: Time.current,
      budgets: @budgets,
      total_project_cases: scoped_cases.distinct.count(:project_case_id),
      uncovered_event_count: @scope.where(project_case_id: nil).count,
      cases: cases,
      status: status_for_cases(cases)
    }
  end

  private

  def scoped_cases
    @scope.where.not(project_case_id: nil)
  end

  def top_case_rows
    scoped_cases
      .select(Arel.sql(TOP_CASES_SELECT))
      .group(:project_case_id)
      .order(Arel.sql('COUNT(*) DESC'), :project_case_id)
      .limit(@limit)
  end

  def build_case_snapshot(row)
    metrics = metrics_for(row)
    checks = checks_for(metrics)

    {
      project_case_id: row.project_case_id,
      event_count: integer_attr(row, 'event_count'),
      request_count: integer_attr(row, 'request_count'),
      event_error_count: integer_attr(row, 'event_error_count'),
      request_error_count: integer_attr(row, 'request_error_count'),
      status: status_for_checks(checks),
      metrics: metrics,
      checks: checks
    }
  end

  def metrics_for(row)
    request_count = integer_attr(row, 'request_count')
    request_estimated_cost = numeric_attr(row, 'request_estimated_cost')

    {
      avg_duration_ms: numeric_attr(row, 'avg_duration_ms', precision: 2),
      p95_duration_ms: numeric_attr(row, 'p95_duration_ms', precision: 2),
      p99_duration_ms: numeric_attr(row, 'p99_duration_ms', precision: 2),
      avg_queue_wait_ms: numeric_attr(row, 'avg_queue_wait_ms', precision: 2),
      p95_queue_wait_ms: numeric_attr(row, 'p95_queue_wait_ms', precision: 2),
      avg_payload_bytes: numeric_attr(row, 'avg_payload_bytes', precision: 2),
      p95_payload_bytes: numeric_attr(row, 'p95_payload_bytes', precision: 2),
      max_payload_bytes: integer_attr(row, 'max_payload_bytes'),
      avg_total_tokens: numeric_attr(row, 'avg_total_tokens', precision: 2),
      p95_total_tokens: numeric_attr(row, 'p95_total_tokens', precision: 2),
      total_estimated_cost: numeric_attr(row, 'total_estimated_cost', precision: 8) || 0.0,
      avg_cost_per_request: request_count.positive? ? ratio(request_estimated_cost.to_f, request_count) : nil,
      request_error_rate: request_count.positive? ? ratio(integer_attr(row, 'request_error_count'), request_count) : nil,
      payload_truncated_count: integer_attr(row, 'payload_truncated_count'),
      retry_occurrences: integer_attr(row, 'retry_occurrences'),
      tool_call_occurrences: integer_attr(row, 'tool_call_occurrences')
    }
  end

  def checks_for(metrics)
    CHECKS.filter_map do |definition|
      value = metrics[definition[:metric]]
      budget = @budgets[definition[:budget]]
      next if value.nil? || budget.nil?

      {
        name: definition[:name],
        status: value.to_f <= budget.to_f ? 'pass' : 'fail',
        value: value,
        budget: budget
      }
    end
  end

  def status_for_cases(cases)
    return 'insufficient_data' if cases.empty?
    return 'fail' if cases.any? { |entry| entry[:status] == 'fail' }

    'pass'
  end

  def status_for_checks(checks)
    return 'unbudgeted' if checks.empty?
    return 'fail' if checks.any? { |check| check[:status] == 'fail' }

    'pass'
  end

  def integer_attr(row, name)
    row.read_attribute(name).to_i
  end

  def numeric_attr(row, name, precision: nil)
    value = row.read_attribute(name)
    return if value.nil?

    number = value.to_f
    precision ? number.round(precision) : number
  end

  def ratio(numerator, denominator)
    return 0.0 if denominator.to_i.zero?

    (numerator.to_f / denominator).round(8)
  end
end
