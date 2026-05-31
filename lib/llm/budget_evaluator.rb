# frozen_string_literal: true

class Llm::BudgetEvaluator
  ERROR_CODE = 'budget_blocked'
  WARNING_CODE = 'budget_warning'

  Decision = Struct.new(
    :allowed,
    :reason,
    :policy,
    :feature,
    :limit_period,
    :limit,
    :current_spend,
    :projected_spend,
    :request_estimated_cost,
    :warning_threshold,
    keyword_init: true
  ) do
    def allowed? = allowed == true
    def blocked? = !allowed?
    def warning? = allowed? && reason.to_s.end_with?('_warning')

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        policy_id: policy&.id,
        feature: feature,
        limit_period: limit_period,
        limit: limit,
        current_spend: current_spend,
        projected_spend: projected_spend,
        request_estimated_cost: request_estimated_cost,
        warning_threshold: warning_threshold
      }.compact
    end
  end

  class BudgetExceededError < StandardError
    attr_reader :decision

    def initialize(decision)
      @decision = decision
      super("LLM budget policy blocked request: #{decision.reason}")
    end
  end

  class << self
    def evaluate(request:, model: nil, estimated_cost: nil, at: Time.current)
      new(request: request, model: model, estimated_cost: estimated_cost, at: at).evaluate
    end

    def evaluate!(request:, model: nil, estimated_cost: nil, at: Time.current)
      decision = evaluate(request: request, model: model, estimated_cost: estimated_cost, at: at)
      publish_budget_event(request: request, model: model, decision: decision) if decision.warning? || decision.blocked?
      return decision if decision.allowed?

      raise BudgetExceededError, decision
    end

    private

    def publish_budget_event(request:, model:, decision:)
      event_name = decision.blocked? ? 'budget.blocked' : 'budget.warning'
      payload = budget_event_payload(request: request, model: model, decision: decision)
      if notification_subscribers?(event_name)
        Llm::EventBus.publish(event_name, payload)
      else
        record_budget_event(event_name: event_name, payload: payload)
      end
    rescue StandardError => e
      Rails.logger.warn("[Llm::BudgetEvaluator] Failed to publish budget event: #{e.class}: #{e.message}")
      nil
    end

    def notification_subscribers?(event_name)
      ActiveSupport::Notifications.notifier.listeners_for("llm.#{event_name}").any?
    end

    def record_budget_event(event_name:, payload:)
      now = Time.current
      Llm::Monitoring::EventRecorder.record_notification(
        event_name: "llm.#{event_name}",
        started_at: now,
        finished_at: now,
        payload: payload.merge(canonical_event_name: "llm.#{event_name}")
      )
    end

    def budget_event_payload(request:, model:, decision:)
      {
        account_id: account_id(request.account),
        feature: request.feature_key,
        provider: 'openrouter',
        model: model || request.model,
        runtime_mode: 'openrouter_runtime',
        status: decision.blocked? ? 'blocked' : 'warning',
        reason: decision.reason,
        blocked: decision.blocked?,
        error: decision.blocked?,
        error_code: decision.blocked? ? ERROR_CODE : WARNING_CODE,
        estimated_cost: decision.request_estimated_cost,
        budget_decision: decision.to_h
      }.compact
    end

    def account_id(account)
      account.respond_to?(:id) ? account.id : account
    end
  end

  def initialize(request:, model:, estimated_cost:, at:)
    @request = request
    @model = model
    @estimated_cost = decimal_value(estimated_cost || request_estimated_cost, default: BigDecimal(0))
    @at = at
  end

  def evaluate
    return Decision.new(allowed: true, reason: 'no_policy', feature: feature) if request_account_id.blank?

    policies.each do |policy|
      decision = limit_decision(policy)
      return decision if decision.present?
    end

    policies.each do |policy|
      decision = warning_decision(policy)
      return decision if decision.present?
    end

    policy = policies.first
    return within_budget_decision(policy) if policy.present?

    Decision.new(allowed: true, reason: 'no_policy', feature: feature)
  end

  private

  attr_reader :request, :model, :estimated_cost, :at

  def policies
    @policies ||= begin
      matching = LlmBudgetPolicy.applicable_to(account: request.account, feature: feature).with_budget_limits
      account_id = request_account_id
      account_specific = account_id.present? ? matching.where(account_id: account_id) : LlmBudgetPolicy.none
      account_specific.exists? ? account_specific : matching.where(account_id: nil)
    end
  end

  def limit_decision(policy)
    check = budget_checks(policy).find do |candidate|
      candidate[:limit].present? && policy.hard_stop? && candidate[:projected_spend] >= candidate[:limit]
    end
    return if check.blank?

    decision_for(policy, check, allowed: false, reason: "#{check[:period]}_budget_exceeded")
  end

  def warning_decision(policy)
    check = budget_checks(policy).find do |candidate|
      next false if candidate[:limit].blank? || candidate[:warning_limit].blank?

      candidate[:projected_spend] >= candidate[:warning_limit]
    end
    return if check.blank?

    decision_for(policy, check, allowed: true, reason: "#{check[:period]}_budget_warning")
  end

  def within_budget_decision(policy)
    check = budget_checks(policy).find { |candidate| candidate[:limit].present? }
    check ||= budget_check(policy, :daily, nil, day_range)
    decision_for(policy, check, allowed: true, reason: 'within_budget')
  end

  def budget_checks(policy)
    [
      budget_check(policy, :daily, policy.daily_budget, day_range),
      budget_check(policy, :monthly, policy.monthly_budget, month_range)
    ]
  end

  def budget_check(policy, period, limit, range)
    limit = decimal_value(limit)
    current_spend = Llm::UsageLedger.spend(account: request_account_id, range: range, feature: policy.feature.presence)
    projected_spend = current_spend + estimated_cost
    {
      period: period,
      limit: limit,
      current_spend: current_spend,
      projected_spend: projected_spend,
      warning_limit: warning_limit(limit, policy.warning_threshold)
    }
  end

  def warning_limit(limit, threshold)
    return if limit.blank? || threshold.blank?

    limit * decimal_value(threshold)
  end

  def decision_for(policy, check, allowed:, reason:)
    Decision.new(
      allowed: allowed,
      reason: reason,
      policy: policy,
      feature: feature,
      limit_period: check[:period],
      limit: check[:limit],
      current_spend: check[:current_spend],
      projected_spend: check[:projected_spend],
      request_estimated_cost: estimated_cost,
      warning_threshold: policy.warning_threshold
    )
  end

  def feature
    request.feature_key
  end

  def request_account_id
    account = request.account
    account.respond_to?(:id) ? account.id : account
  end

  def day_range
    at.in_time_zone.all_day
  end

  def month_range
    at.in_time_zone.all_month
  end

  def request_estimated_cost
    request.options[:estimated_cost] || request.options.dig(:budget, :estimated_cost)
  end

  def decimal_value(value, default: nil)
    return default if value.blank?

    value.to_d
  rescue ArgumentError, TypeError
    default
  end
end
