class Api::V1::Accounts::Crm::StageFieldRequirementsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_stage

  def update
    authorize @stage, :update?

    stage = ::Crm::Stages::ReplaceFieldRequirementsService.new(
      stage: @stage,
      requirements: requirement_params
    ).perform

    render_payload(::Crm::PayloadBuilder.stage(stage))
  end

  private

  def set_stage
    @stage = policy_scope(::Crm::Stage).find(params[:stage_id])
  end

  def requirement_params
    params.require(:requirements).map do |requirement|
      requirement.permit(:field_key, :required, validation: {}, role_exemptions: [])
    end
  end
end
