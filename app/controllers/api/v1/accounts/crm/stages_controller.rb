class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:create]
  before_action :set_stage, only: [:update, :destroy]

  def create
    authorize ::Crm::Stage

    stage = @pipeline.with_lock do
      new_stage = @pipeline.stages.new(create_stage_params)
      new_stage.account = Current.account
      new_stage.position = nil
      new_stage.save!
      new_stage
    end

    render_payload(::Crm::PayloadBuilder.stage(stage), status: :created)
  end

  def update
    authorize @stage

    ApplicationRecord.transaction do
      ensure_stage_default_before_deactivation!
      @stage.update!(update_stage_params)
    end

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
    return technical_stage_params if @stage.technical_stage?

    stage_params.except(:outcome, :closing_reason_required, :closing_reason_options)
  end

  def stage_params
    params.permit(
      :name,
      :code,
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

  def technical_stage_params
    params.permit(:active, :color, :transition_reason_required, transition_reason_options: [])
  end

  def ensure_stage_default_before_deactivation!
    return unless @stage.outcome_open?
    return unless params.key?(:active)
    return if ActiveModel::Type::Boolean.new.cast(params[:active])

    active_default_stage = @stage.pipeline.stages.active.find_by(default: true)
    return unless @stage.default? || active_default_stage.blank?

    fallback_stage = @stage.pipeline.stages.active
                           .where(outcome: 'open')
                           .where.not(id: @stage.id)
                           .ordered
                           .first

    if fallback_stage.blank?
      error_code = if @stage.technical_stage?
                     'UNSORTED_STAGE_REQUIRES_FALLBACK'
                   else
                     'DEFAULT_STAGE_REQUIRES_FALLBACK'
                   end
      raise ::Crm::Error.new(
        code: error_code,
        message: 'Create another active open stage before disabling the default stage.',
        status: :unprocessable_content
      )
    end

    @stage.update!(active: false, default: false)
    fallback_stage.update!(default: true)
  end

  def ensure_mutable_stage!
    return unless @stage.system_stage?

    raise ::Crm::Error.new(
      code: 'STANDARD_STAGE_LOCKED',
      message: 'System stages cannot be deleted.',
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
