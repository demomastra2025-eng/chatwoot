class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:create]
  before_action :set_stage, only: [:update]

  def create
    authorize ::Crm::Stage

    stage = @pipeline.stages.new(stage_params)
    stage.account = Current.account
    stage.save!

    render_payload(::Crm::PayloadBuilder.stage(stage), status: :created)
  end

  def update
    authorize @stage
    @stage.update!(stage_params)

    render_payload(::Crm::PayloadBuilder.stage(@stage.reload))
  end

  private

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).find(params[:pipeline_id])
  end

  def set_stage
    @stage = policy_scope(::Crm::Stage).find(params[:id])
  end

  def stage_params
    params.permit(:name, :code, :position, :outcome, :active)
  end
end
