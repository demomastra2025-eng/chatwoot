class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:create, :batch_update]
  before_action :set_stage, only: [:update, :destroy, :deletion_check]

  def create
    authorize ::Crm::Stage

    stage = nil
    @pipeline.with_lock do
      stage = @pipeline.stages.new(create_stage_params)
      stage.account = Current.account
      stage.position = nil unless params.key?(:position)
      stage.save!
    end

    render_payload(::Crm::PayloadBuilder.stage(stage.reload), status: :created)
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
    @stage.pipeline.with_lock do
      @stage.reload
      update_stage_with_default_fallback!(update_stage_params)
    end

    render_payload(::Crm::PayloadBuilder.stage(@stage.reload))
  end

  def destroy
    authorize @stage
    @stage.pipeline.with_lock do
      @stage.reload
      ensure_mutable_stage!
      ensure_destroyable_stage!
      promote_default_stage_fallback!
      @stage.destroy!
    end

    head :no_content
  end

  def deletion_check
    authorize @stage, :destroy?

    deal_count = @stage.deals.count
    block_reason = stage_deletion_block_reason(deal_count)
    render_payload({
      stage_id: @stage.id,
      can_delete: block_reason.nil?,
      deal_count: deal_count,
      block_reason: block_reason
    })
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

  def batch_update_params
    params.permit(
      deleted_stage_ids: [],
      stages: [
        :id,
        :name,
        :color,
        :active,
        :default,
        :transition_reason_required,
        { transition_reason_options: [] },
      ],
      terminal_stages: [
        :id,
        :name,
        :closing_reason_required,
        { closing_reason_options: [] },
      ]
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

  def update_stage_with_default_fallback!(attributes)
    unless @stage.outcome_open? && params.key?(:active) && !parse_boolean(params[:active])
      @stage.update!(attributes)
      return
    end

    active_default_stage = @stage.pipeline.stages.active.find_by(default: true)
    unless @stage.default? || active_default_stage.blank?
      @stage.update!(attributes)
      return
    end

    fallback_stage = active_open_fallback_stage
    unless fallback_stage
      raise ::Crm::Error.new(
        code: 'DEFAULT_STAGE_REQUIRES_FALLBACK',
        message: 'The default stage needs another active open stage before it can be deactivated or deleted.',
        status: :unprocessable_content
      )
    end

    @stage.update!(attributes.merge(active: false, default: false))
    fallback_stage.update!(default: true)
  end

  def promote_default_stage_fallback!
    return unless @stage.default?

    fallback_stage = active_open_fallback_stage
    unless fallback_stage
      raise ::Crm::Error.new(
        code: 'DEFAULT_STAGE_REQUIRES_FALLBACK',
        message: 'The default stage needs another active open stage before it can be deactivated or deleted.',
        status: :unprocessable_content
      )
    end

    fallback_stage.update!(default: true)
  end

  def active_open_fallback_stage
    candidates = @stage.pipeline.stages.active
                       .where(outcome: 'open')
                       .where.not(id: @stage.id)

    candidates.first
  end

  def stage_deletion_block_reason(deal_count)
    return 'STANDARD_STAGE_LOCKED' if @stage.terminal_outcome?
    return 'STAGE_HAS_DEALS' unless deal_count.zero?
    return unless @stage.default?
    return if active_open_fallback_stage

    'DEFAULT_STAGE_REQUIRES_FALLBACK'
  end
end
