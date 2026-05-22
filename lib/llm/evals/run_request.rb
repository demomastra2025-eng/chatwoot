# frozen_string_literal: true

class Llm::Evals::RunRequest
  class ValidationError < StandardError; end

  DEFAULT_BUDGET_CENTS = 100
  MAX_BUDGET_CENTS = 500
  DEFAULT_MAX_CASES = 3
  MAX_CASES = 10
  ESTIMATED_LLM_CASE_COST_CENTS = 25
  ACTIVE_RUN_STATUSES = %w[queued running].freeze

  attr_reader :pack_ids

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

    run = create_run!

    ::Llm::Evals::RunJob.perform_later(run.id)
    run
  rescue ActiveRecord::RecordNotUnique
    raise ValidationError, 'llm_model_eval_already_running'
  end

  def queued_llm_model_run?
    selected_packs.any?(&:live_model)
  end

  private

  def validate!
    raise ValidationError, 'eval_pack_required' if @pack_ids.blank?
    raise ValidationError, 'unknown_eval_pack' if selected_packs.blank?
    return unless queued_llm_model_run?

    raise ValidationError, 'llm_model_eval_runs_disabled' unless llm_model_evals_enabled?
    raise ValidationError, 'llm_model_eval_cost_acknowledgement_required' unless @acknowledge_live_cost
    raise ValidationError, 'llm_model_eval_budget_exceeded' if @budget_cents > MAX_BUDGET_CENTS
    raise ValidationError, 'llm_model_eval_case_limit_exceeded' if @max_cases > MAX_CASES
    raise ValidationError, 'llm_model_eval_budget_exceeded' if estimated_llm_cost_cents > @budget_cents
    raise ValidationError, 'llm_model_eval_already_running' if active_llm_model_run_exists?
  end

  def estimated_llm_cost_cents
    @max_cases * live_pack_count * ESTIMATED_LLM_CASE_COST_CENTS
  end

  def live_pack_count
    [selected_packs.count(&:live_model), 1].max
  end

  def selected_packs
    @selected_packs ||= @pack_ids.map { |pack_id| ::Llm::Evals::PackRegistry.find!(pack_id) }
  rescue ArgumentError
    []
  end

  def llm_model_evals_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLM_EVALS_LIVE_ENABLED', 'false'))
  end

  def active_llm_model_run_exists?
    ::Llm::EvalRun
      .where(account: @account, status: ACTIVE_RUN_STATUSES)
      .exists?(["metadata ->> 'queued_llm_model_run' = ?", 'true'])
  end

  def create_run!
    ::Llm::EvalRun.create!(
      account: @account,
      user: @user,
      status: 'queued',
      mode: 'evals',
      pack_ids: @pack_ids,
      requested_budget_cents: queued_llm_model_run? ? @budget_cents : 0,
      max_cases: queued_llm_model_run? ? @max_cases : nil,
      metadata: {
        requested_by_user_id: @user&.id,
        requested_by_email: @user&.email,
        llm_model_evals_enabled: llm_model_evals_enabled?,
        queued_llm_model_run: queued_llm_model_run?,
        estimated_llm_cost_cents: queued_llm_model_run? ? estimated_llm_cost_cents : nil
      }.compact
    )
  end

  def normalize_integer(value, fallback)
    normalized = value.to_i
    normalized.positive? ? normalized : fallback
  end
end
