class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  include ::Api::V1::Accounts::Crm::Concerns::StageParameterSupport
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
      ::Crm::Stages::UnsortedDeactivationGuard.ensure_empty!(@stage) if open_stage_deactivation_requested? && @stage.active?
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
    blocker = stage_deletion_blocker

    render json: {
      payload: {
        deletable: blocker.nil?,
        can_delete: blocker.nil?,
        deal_count: @stage.deals.count,
        block_reason: blocker
      }.compact
    }
  end

  private

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).find(params[:pipeline_id])
  end

  def set_stage
    @stage = policy_scope(::Crm::Stage).find(params[:id])
  end

  def batch_update_params
    params.permit(
      deleted_stage_ids: [],
      stages: MOVABLE_STAGE_PARAMS,
      technical_stage: [:id, :active],
      terminal_stages: TERMINAL_STAGE_PARAMS,
      pipeline_rules: [:restrict_stage_skipping, :restrict_backward_move, :allow_stage_rule_override]
    )
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
    return unless open_stage_deactivation_requested?
    return unless default_stage_replacement_required?

    fallback_stage = required_default_stage_fallback!
    @stage.update!(active: false, default: false)
    fallback_stage.update!(default: true)
  end

  def open_stage_deactivation_requested?
    @stage.outcome_open? && params.key?(:active) && !ActiveModel::Type::Boolean.new.cast(params[:active])
  end

  def default_stage_replacement_required?
    @stage.default? || @stage.pipeline.stages.active.find_by(default: true).blank?
  end

  def required_default_stage_fallback!
    default_stage_fallback || raise(
      ::Crm::Error.new(
        code: @stage.technical_stage? ? 'UNSORTED_STAGE_REQUIRES_FALLBACK' : 'DEFAULT_STAGE_REQUIRES_FALLBACK',
        message: 'Create another active open stage before disabling the default stage.',
        status: :unprocessable_content
      )
    )
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
    ::Crm::DealPresenceGuard.ensure_empty!(@stage)
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

  def stage_deletion_blocker
    return 'STANDARD_STAGE_LOCKED' if @stage.system_stage?
    return 'STAGE_HAS_DEALS' if @stage.deals.exists?
    return 'STAGE_HAS_HISTORY' if ::Crm::DealPresenceGuard.history_blocked?(@stage)
    return 'DEFAULT_STAGE_REQUIRES_FALLBACK' if @stage.outcome_open? && @stage.default? && default_stage_fallback.blank?

    nil
  end
end
