class Api::V1::Accounts::Crm::PipelinesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:show, :update, :destroy, :reorder_stages]

  def index
    authorize ::Crm::Pipeline
    bootstrap_defaults!

    pipelines = policy_scope(::Crm::Pipeline).includes(:stages).ordered
    render_payload(
      pipelines.map do |pipeline|
        ::Crm::PayloadBuilder.pipeline(pipeline, include_inactive_stages: include_inactive_stages?)
      end,
      meta: { count: pipelines.size }
    )
  end

  def show
    authorize @pipeline
    render_payload(::Crm::PayloadBuilder.pipeline(@pipeline))
  end

  def create
    authorize ::Crm::Pipeline

    pipeline = nil
    ApplicationRecord.transaction do
      lock_account_for_pipeline_defaults!
      pipeline = Current.account.crm_pipelines.new(pipeline_params)
      pipeline.position = nil unless params.key?(:position)
      pipeline.save!
      ::Crm::Pipelines::DefaultStageBuilder.new(pipeline: pipeline).perform
    end

    render_payload(::Crm::PayloadBuilder.pipeline(pipeline.reload), status: :created)
  end

  def update
    authorize @pipeline

    ApplicationRecord.transaction do
      lock_account_for_pipeline_defaults!
      @pipeline.lock!
      was_default = @pipeline.active? && @pipeline.default?
      set_auto_create_default_stage!
      @pipeline.update!(pipeline_params)
      promote_default_pipeline! if was_default && (!@pipeline.active? || !@pipeline.default?)
    end

    render_payload(::Crm::PayloadBuilder.pipeline(@pipeline.reload))
  end

  def destroy
    authorize @pipeline

    ApplicationRecord.transaction do
      lock_account_for_pipeline_defaults!
      @pipeline.lock!
      ensure_destroyable_pipeline!
      was_default = @pipeline.default?
      @pipeline.destroy!
      promote_default_pipeline! if was_default
    end

    head :no_content
  end

  def reorder_stages
    authorize @pipeline
    ordered_stage_ids = Array(params[:stage_ids]).map(&:to_i)

    ApplicationRecord.transaction do
      @pipeline.lock!
      movable_stages = movable_stages_scope
      ensure_complete_stage_order!(movable_stages, ordered_stage_ids)
      persist_stage_order!(movable_stages, ordered_stage_ids)
    end

    render_payload(
      ::Crm::PayloadBuilder.pipeline(@pipeline.reload, include_inactive_stages: true)
    )
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def pipeline_params
    params.permit(:name, :code, :position, :active, :default, :auto_create_deal_on_channel_contact)
  end

  def set_auto_create_default_stage!
    return if params[:auto_create_stage_id].blank?

    stage = @pipeline.stages.active.find_by(
      id: params[:auto_create_stage_id],
      outcome: 'open'
    )
    if stage.blank?
      raise ::Crm::Error.new(
        code: 'INVALID_AUTO_CREATE_STAGE',
        message: 'Auto-created deals require an active open stage from the selected pipeline.',
        status: :unprocessable_content
      )
    end

    stage.update!(default: true)
  end

  def include_inactive_stages?
    ActiveModel::Type::Boolean.new.cast(params[:include_inactive_stages])
  end

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).includes(:stages).find(params[:id])
  end

  def ensure_destroyable_pipeline!
    return unless @pipeline.deals.exists?

    raise ::Crm::Error.new(
      code: 'PIPELINE_HAS_DEALS',
      message: 'You cannot delete a pipeline while it still has deals. Move all open and closed deals to stages in another pipeline first.',
      status: :unprocessable_content
    )
  end

  def promote_default_pipeline!
    replacement = Current.account.crm_pipelines.active.ordered.lock.first
    replacement&.update!(default: true)
  end

  def lock_account_for_pipeline_defaults!
    Current.account.lock!
  end

  def ensure_complete_stage_order!(movable_stages, ordered_stage_ids)
    expected_stage_ids = movable_stages.pluck(:id)
    return if ordered_stage_ids.length == expected_stage_ids.length && ordered_stage_ids.sort == expected_stage_ids.sort

    raise ::Crm::Error.new(
      code: 'INVALID_STAGE_ORDER',
      message: 'Stage order must contain every movable stage in this pipeline exactly once.',
      status: :unprocessable_content
    )
  end

  def movable_stages_scope
    @pipeline.stages
             .where(outcome: 'open')
             .where.not(code: ::Crm::Stage::TECHNICAL_STAGE_CODES)
  end

  def persist_stage_order!(movable_stages, ordered_stage_ids)
    stages_by_id = movable_stages.index_by(&:id)
    ordered_stage_ids.each_with_index do |stage_id, index|
      stages_by_id.fetch(stage_id).update!(position: index + 1)
    end

    @pipeline.stages.where(code: ::Crm::Stage::TECHNICAL_STAGE_CODES).find_each do |stage|
      stage.update!(position: 0) unless stage.position.zero?
    end

    @pipeline.stages.where(outcome: ::Crm::Stage::TERMINAL_OUTCOMES).ordered.each_with_index do |stage, index|
      stage.update!(position: ordered_stage_ids.length + index + 1)
    end
  end
end
