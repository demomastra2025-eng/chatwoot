class Api::V1::Accounts::Crm::PipelinesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_pipeline, only: [:show, :update, :destroy]

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
      pipeline = Current.account.crm_pipelines.new(pipeline_params)
      pipeline.position = nil unless params.key?(:position)
      pipeline.save!
      ::Crm::Pipelines::DefaultStageBuilder.new(pipeline: pipeline).perform
    end

    render_payload(::Crm::PayloadBuilder.pipeline(pipeline.reload), status: :created)
  end

  def update
    authorize @pipeline
    @pipeline.update!(pipeline_params)

    render_payload(::Crm::PayloadBuilder.pipeline(@pipeline.reload))
  end

  def destroy
    authorize @pipeline
    ensure_archived_pipeline!
    ensure_destroyable_pipeline!
    @pipeline.destroy!

    head :no_content
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def pipeline_params
    params.permit(:name, :code, :position, :active, :default, :auto_create_deal_on_channel_contact)
  end

  def include_inactive_stages?
    ActiveModel::Type::Boolean.new.cast(params[:include_inactive_stages])
  end

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).includes(:stages).find(params[:id])
  end

  def ensure_archived_pipeline!
    return unless @pipeline.active?

    raise ::Crm::Error.new(
      code: 'PIPELINE_MUST_BE_ARCHIVED',
      message: 'You can only delete an archived pipeline.',
      status: :unprocessable_content
    )
  end

  def ensure_destroyable_pipeline!
    return unless @pipeline.deals.exists?

    raise ::Crm::Error.new(
      code: 'PIPELINE_HAS_DEALS',
      message: 'You cannot delete a pipeline while it still has deals. Move all open and closed deals to stages in another pipeline first.',
      status: :unprocessable_content
    )
  end
end
