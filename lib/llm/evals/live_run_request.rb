# frozen_string_literal: true

class Llm::Evals::LiveRunRequest
  class ValidationError < StandardError; end

  DEFAULT_BUDGET_CENTS = 100
  MAX_BUDGET_CENTS = 500
  DEFAULT_MAX_CASES = 3
  MAX_CASES = 10

  def initialize(account:, user:, pack_ids:, acknowledge_live_cost:, budget_cents: nil, max_cases: nil)
    @account = account
    @user = user
    @pack_ids = Array(pack_ids).filter_map { |id| id.to_s.presence }
    @acknowledge_live_cost = ActiveModel::Type::Boolean.new.cast(acknowledge_live_cost)
    @budget_cents = normalize_integer(budget_cents, DEFAULT_BUDGET_CENTS)
    @max_cases = normalize_integer(max_cases, DEFAULT_MAX_CASES)
  end

  def call
    validate!

    run = ::Llm::EvalRun.create!(
      account: @account,
      user: @user,
      status: 'queued',
      mode: 'live_model',
      pack_ids: live_pack_ids,
      requested_budget_cents: @budget_cents,
      max_cases: @max_cases,
      metadata: {
        requested_by_user_id: @user&.id,
        requested_by_email: @user&.email,
        live_evals_enabled: live_evals_enabled?
      }.compact
    )

    ::Llm::Evals::LiveRunJob.perform_later(run.id)
    run
  end

  private

  def validate!
    raise ValidationError, 'live_eval_runs_disabled' unless live_evals_enabled?
    raise ValidationError, 'live_eval_cost_acknowledgement_required' unless @acknowledge_live_cost
    raise ValidationError, 'live_eval_pack_required' if live_pack_ids.blank?
    raise ValidationError, 'live_eval_budget_exceeded' if @budget_cents > MAX_BUDGET_CENTS
    raise ValidationError, 'live_eval_case_limit_exceeded' if @max_cases > MAX_CASES
  end

  def live_pack_ids
    @live_pack_ids ||= @pack_ids.select do |pack_id|
      ::Llm::Evals::PackRegistry.find!(pack_id).live_model
    end
  end

  def live_evals_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLM_EVALS_LIVE_ENABLED', 'false'))
  end

  def normalize_integer(value, fallback)
    normalized = value.to_i
    normalized.positive? ? normalized : fallback
  end
end
