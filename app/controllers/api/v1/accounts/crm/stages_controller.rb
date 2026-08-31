class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:create, :batch_update]
  before_action :set_stage, only: [:update, :destroy, :deletion_check]

  def create
    authorize ::Crm::Stage

    stage = @pipeline.with_lock do
      attributes = create_stage_params
      requested_position = attributes.delete(:position)
      new_stage = @pipeline.stages.new(attributes)
      new_stage.account = Current.account
      insert_stage_at!(new_stage, requested_position)
      new_stage.save!
      new_stage
    end

    render_payload(::Crm::PayloadBuilder.stage(stage), status: :created)
  end

  def batch_update
    authorize @pipeline, :update?
    pipeline = ::Crm::Stages::BatchUpdateService.new(
      pipeline: @pipeline,
      attributes: batch_update_params
    ).perform

    render_payload(::Crm::PayloadBuilder.pipeline(pipeline, include_inactive_stages: true))
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
    @stage.pipeline.with_lock do
      @stage.lock!
      ensure_mutable_stage!
      ensure_destroyable_stage!
      fallback_stage = default_stage_fallback_for_destroy!
      @stage.destroy!
      fallback_stage&.update!(default: true)
    end

    head :no_content
  end

  def deletion_check
    authorize @stage, :destroy?
    ensure_mutable_stage!
    ensure_destroyable_stage!
    default_stage_fallback_for_destroy!

    render json: { payload: { deletable: true } }
  end

  private

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).find(params[:pipeline_id])
  end

  def set_stage
    @stage = policy_scope(::Crm::Stage).find(params[:id])
  end

  def create_stage_params
    attributes = stage_params.except(:outcome).merge(outcome: 'open')
    attributes[:position] = params.permit(:position)[:position] if params.key?(:position)
    attributes
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

  def batch_update_params
    params.permit(
      deleted_stage_ids: [],
      stages: [:id, :name, :color, :active],
      technical_stage: [:id, :active],
      terminal_stages: [:id, :name, { closing_reason_options: [] }]
    )
  end

  def terminal_stage_params
    params.permit(:name, :closing_reason_required, closing_reason_options: [])
  end

  def technical_stage_params
    params.permit(:active, :color, :transition_reason_required, transition_reason_options: [])
  end

  def insert_stage_at!(stage, requested_position)
    if requested_position.blank?
      stage.position = nil
      return
    end

    first_terminal_position = @pipeline.stages.where(outcome: ::Crm::Stage::TERMINAL_OUTCOMES).minimum(:position)
    last_insert_position = first_terminal_position || (@pipeline.stages.maximum(:position).to_i + 1)
    stage.position = requested_position.to_i.clamp(1, last_insert_position)

    @pipeline.stages
             .where('position >= ?', stage.position)
             .order(position: :desc, id: :desc)
             .each { |sibling| sibling.update!(position: sibling.position + 1) }
  end

  def ensure_stage_default_before_deactivation!
    return unless @stage.outcome_open?
    return unless params.key?(:active)
    return if ActiveModel::Type::Boolean.new.cast(params[:active])

    active_default_stage = @stage.pipeline.stages.active.find_by(default: true)
    return unless @stage.default? || active_default_stage.blank?

    fallback_stage = default_stage_fallback

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

  def default_stage_fallback_for_destroy!
    return unless @stage.outcome_open? && @stage.default?

    fallback_stage = default_stage_fallback
    return fallback_stage if fallback_stage

    raise ::Crm::Error.new(
      code: 'DEFAULT_STAGE_REQUIRES_FALLBACK',
      message: 'Create another active open stage before deleting the default stage.',
      status: :unprocessable_content
    )
  end

  def default_stage_fallback
    candidates = @stage.pipeline.stages.active
                       .where(outcome: 'open')
                       .where.not(id: @stage.id)
    candidates.where.not(code: ::Crm::Stage::TECHNICAL_STAGE_CODES).ordered.first || candidates.ordered.first
  end
end
