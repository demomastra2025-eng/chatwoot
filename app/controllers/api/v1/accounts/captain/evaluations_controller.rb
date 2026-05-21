# frozen_string_literal: true

class Api::V1::Accounts::Captain::EvaluationsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: { packs: Llm::Evals::PackRegistry.catalog }
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

  private

  def live_eval_requested?
    ActiveModel::Type::Boolean.new.cast(params[:include_live]) ||
      permitted_pack_ids.any? { |pack_id| Llm::Evals::PackRegistry.find!(pack_id).live_model }
  end

  def permitted_pack_ids
    @permitted_pack_ids ||= Array(params.permit(pack_ids: [])[:pack_ids])
  end
end
