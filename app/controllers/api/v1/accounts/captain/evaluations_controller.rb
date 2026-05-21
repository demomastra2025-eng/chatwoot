# frozen_string_literal: true

class Api::V1::Accounts::Captain::EvaluationsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: {
      packs: Llm::Evals::PackRegistry.catalog,
      live_evals: live_eval_config,
      latest_live_run: latest_live_run&.summary
    }
  end

  def run
    if live_eval_requested?
      render json: { error: 'live_eval_runs_not_enabled' }, status: :unprocessable_content
      return
    end

    result = Llm::Evals::Runner.new(
      account: @current_account,
      pack_ids: permitted_pack_ids,
      include_live: false
    ).call

    render json: { packs: Llm::Evals::PackRegistry.catalog, result: result.to_h }
  end

  def run_live
    run = Llm::Evals::LiveRunRequest.new(
      account: @current_account,
      user: current_user,
      pack_ids: permitted_pack_ids,
      acknowledge_live_cost: params[:acknowledge_live_cost],
      budget_cents: params[:budget_cents],
      max_cases: params[:max_cases]
    ).call

    render json: {
      packs: Llm::Evals::PackRegistry.catalog,
      live_evals: live_eval_config,
      run: run.summary
    }, status: :accepted
  rescue Llm::Evals::LiveRunRequest::ValidationError => e
    render json: { error: e.message, live_evals: live_eval_config }, status: :unprocessable_content
  end

  def live_run
    run = Llm::EvalRun.where(account: @current_account).find(params[:run_id])
    render json: { run: run.summary }
  end

  def import_conversation
    exported = Llm::Evals::AiVoiceTraceExporter.new(
      account: @current_account,
      inbox_id: params[:inbox_id],
      display_id: params[:display_id]
    ).call

    render json: exported
  end

  private

  def live_eval_requested?
    ActiveModel::Type::Boolean.new.cast(params[:include_live]) ||
      permitted_pack_ids.any? { |pack_id| Llm::Evals::PackRegistry.find!(pack_id).live_model }
  end

  def permitted_pack_ids
    @permitted_pack_ids ||= Array(params.permit(pack_ids: [])[:pack_ids])
  end

  def live_eval_config
    {
      enabled: ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLM_EVALS_LIVE_ENABLED', 'false')),
      max_budget_cents: Llm::Evals::LiveRunRequest::MAX_BUDGET_CENTS,
      default_budget_cents: Llm::Evals::LiveRunRequest::DEFAULT_BUDGET_CENTS,
      max_cases: Llm::Evals::LiveRunRequest::MAX_CASES,
      default_max_cases: Llm::Evals::LiveRunRequest::DEFAULT_MAX_CASES
    }
  end

  def latest_live_run
    Llm::EvalRun.where(account: @current_account).recent.first
  end
end
