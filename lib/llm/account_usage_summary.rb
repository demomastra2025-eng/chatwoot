# frozen_string_literal: true

class Llm::AccountUsageSummary
  PROVIDER = 'openrouter'
  RECENT_ERROR_LIMIT = 5
  TOP_LIMIT = 5

  def self.call(account:, at: Time.current)
    new(account: account, at: at).call
  end

  def initialize(account:, at: Time.current)
    @account = account
    @at = at
  end

  def call
    {
      generated_at: at.iso8601,
      currency: 'USD',
      windows: windows_payload,
      budgets: budgets_payload,
      top_models: top_models,
      top_features: top_features,
      recent_errors: recent_errors,
      runtime_health: runtime_health
    }
  end

  private

  attr_reader :account, :at

  def windows_payload
    {
      today: usage_summary(at.in_time_zone.all_day),
      month: usage_summary(at.in_time_zone.all_month),
      last_7_days: usage_summary((at - 7.days)..at)
    }
  end

  def usage_summary(range)
    Llm::UsageLedger.summary(account: account, range: range, provider: PROVIDER)
  end

  def budgets_payload
    policies = LlmBudgetPolicy.applicable_to(account: account, feature: nil)
                              .where(feature: nil)
                              .with_budget_limits
    account_policy = account_budget_policy
    {
      account_policy: account_policy ? policy_payload(account_policy) : default_policy_payload,
      effective_policies: policies.map { |policy| policy_payload(policy) }
    }
  end

  def account_budget_policy
    LlmBudgetPolicy.find_by(account_id: account.id, scope_type: 'account', feature: nil)
  end

  def default_policy_payload
    {
      id: nil,
      scope_type: 'account',
      feature: nil,
      active: false,
      hard_stop: false,
      warning_threshold: 0.8,
      daily_budget: nil,
      monthly_budget: nil,
      daily: budget_window_payload(nil, at.in_time_zone.all_day),
      monthly: budget_window_payload(nil, at.in_time_zone.all_month)
    }
  end

  def policy_payload(policy)
    {
      id: policy.id,
      scope_type: policy.scope_type,
      feature: policy.feature,
      active: policy.active?,
      hard_stop: policy.hard_stop?,
      warning_threshold: decimal_float(policy.warning_threshold),
      daily_budget: decimal_float(policy.daily_budget),
      monthly_budget: decimal_float(policy.monthly_budget),
      fallback_profile: policy.fallback_profile,
      daily: budget_window_payload(policy.daily_budget, at.in_time_zone.all_day, warning_threshold: policy.warning_threshold),
      monthly: budget_window_payload(policy.monthly_budget, at.in_time_zone.all_month, warning_threshold: policy.warning_threshold)
    }.compact
  end

  def budget_window_payload(limit, range, warning_threshold: 0.8)
    spend = Llm::UsageLedger.spend(account: account, range: range, provider: PROVIDER)
    limit_decimal = decimal_value(limit)
    threshold = decimal_value(warning_threshold) || BigDecimal('0.8')
    {
      spend: decimal_float(spend),
      limit: decimal_float(limit_decimal),
      remaining: limit_decimal.present? ? decimal_float([limit_decimal - spend, BigDecimal(0)].max) : nil,
      percent_used: percent_used(spend, limit_decimal),
      status: budget_status(spend, limit_decimal, threshold)
    }
  end

  def percent_used(spend, limit)
    return if limit.blank? || limit.zero?

    ((spend / limit) * 100).round(2).to_f
  end

  def budget_status(spend, limit, warning_threshold)
    return 'not_configured' if limit.blank?
    return 'exceeded' if spend >= limit

    warning_limit = limit * warning_threshold
    return 'warning' if spend >= warning_limit

    'ok'
  end

  def top_models = top_usage_by(:actual_model)

  def top_features = top_usage_by(:feature)

  def top_usage_by(column)
    usage_scope
      .where.not(column => [nil, ''])
      .group(column)
      .select(
        column,
        Arel.sql('COUNT(*) AS request_count'),
        Arel.sql('COALESCE(SUM(total_tokens), 0) AS total_tokens_sum'),
        Arel.sql('COALESCE(SUM(estimated_cost), 0) AS estimated_cost_sum')
      )
      .sort_by { |row| -decimal_attr(row, 'estimated_cost_sum') }
      .first(TOP_LIMIT)
      .map { |row| aggregate_row_payload(row, column) }
  end

  def aggregate_row_payload(row, key)
    { key => row.public_send(key) }.merge(
      request_count: row.read_attribute('request_count').to_i,
      total_tokens: row.read_attribute('total_tokens_sum').to_i,
      estimated_cost: decimal_float(decimal_attr(row, 'estimated_cost_sum'))
    )
  end

  def recent_errors
    usage_scope
      .where.not(error_code: [nil, ''])
      .or(usage_scope.where(status: %w[error failed blocked]))
      .order(occurred_at: :desc)
      .limit(RECENT_ERROR_LIMIT)
      .map do |event|
        {
          occurred_at: event.occurred_at&.iso8601,
          feature: event.feature,
          model: event.actual_model.presence || event.requested_model,
          status: event.status,
          error_code: event.error_code,
          trace_id: event.trace_id,
          request_id: event.request_id
        }.compact
      end
  end

  def runtime_health
    events = LlmEvent.for_account(account.id)
                     .where(provider: PROVIDER)
                     .for_date_range((at - 24.hours)..at)
    {
      window_hours: 24,
      total_events: events.count,
      error_count: events.error_events.count,
      retry_count: events.sum(:retry_count),
      schema_invalid_count: events.schema_invalid_events.count,
      tool_failure_count: events.tool_failure_events.count,
      last_event_at: events.maximum(:created_at)&.iso8601
    }
  end

  def usage_scope
    @usage_scope ||= Llm::UsageLedger.usage_scope(account: account, provider: PROVIDER)
  end

  def decimal_value(value)
    return if value.blank?

    value.to_d
  rescue ArgumentError, TypeError
    nil
  end

  def decimal_float(value)
    decimal_value(value)&.to_f
  end

  def decimal_attr(row, name)
    value = row.read_attribute(name)
    value.respond_to?(:to_d) ? value.to_d : BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal(0)
  end
end
