class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:create]
  before_action :set_stage, only: [:update, :destroy]

  def create
    authorize ::Crm::Stage

    stage = @pipeline.stages.new(create_stage_params)
    stage.account = Current.account
    stage.position = nil unless params.key?(:position)
    stage.save!

    render_payload(::Crm::PayloadBuilder.stage(stage), status: :created)
  end

  def update
    authorize @stage
    @stage.update!(update_stage_params)

    render_payload(::Crm::PayloadBuilder.stage(@stage.reload))
  end

  def destroy
    authorize @stage
    ensure_mutable_stage!
    ensure_destroyable_stage!
    @stage.destroy!

    head :no_content
  end

  private

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).find(params[:pipeline_id])
  end

  def set_stage
    @stage = policy_scope(::Crm::Stage).find(params[:id])
  end

  def create_stage_params
    stage_params.except(:outcome).merge(outcome: 'open')
  end

  def update_stage_params
    return terminal_stage_params if @stage.terminal_outcome?

    stage_params.except(:outcome, :closing_reason_required, :closing_reason_options)
  end

  def stage_params
    params.permit(
      :name,
      :code,
      :position,
      :outcome,
      :active,
      :color,
      :default,
      :closing_reason_required,
      :transition_reason_required,
      closing_reason_options: [],
      transition_reason_options: []
    )
  end

  def terminal_stage_params
    params.permit(:name, :closing_reason_required, closing_reason_options: [])
  end

  def ensure_mutable_stage!
    return unless @stage.terminal_outcome?

    raise ::Crm::Error.new(
      code: 'STANDARD_STAGE_LOCKED',
      message: 'Standard won/lost stages can only be renamed or configured with closing reasons.',
      status: :unprocessable_content
    )
  end

  def ensure_destroyable_stage!
    return unless @stage.deals.exists?

    raise ::Crm::Error.new(
      code: 'STAGE_HAS_DEALS',
      message: 'You cannot delete a stage while it still has deals. Move all open and closed deals to another stage first.',
      status: :unprocessable_content
    )
  end
end
