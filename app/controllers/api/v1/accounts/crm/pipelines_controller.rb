class Api::V1::Accounts::Crm::PipelinesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :bootstrap_defaults!, only: [:index]
  before_action :set_pipeline, only: [:show, :update]

  def index
    authorize ::Crm::Pipeline

    pipelines = policy_scope(::Crm::Pipeline).includes(:stages).ordered
    render_payload(
      pipelines.map { |pipeline| ::Crm::PayloadBuilder.pipeline(pipeline) },
      meta: { count: pipelines.size }
    )
  end

  def show
    authorize @pipeline
    render_payload(::Crm::PayloadBuilder.pipeline(@pipeline))
  end

  def create
    authorize ::Crm::Pipeline

    pipeline = Current.account.crm_pipelines.new(pipeline_params)
    pipeline.save!

    render_payload(::Crm::PayloadBuilder.pipeline(pipeline.reload), status: :created)
  end

  def update
    authorize @pipeline
    @pipeline.update!(pipeline_params)

    render_payload(::Crm::PayloadBuilder.pipeline(@pipeline.reload))
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def pipeline_params
    params.permit(:name, :code, :position, :active, :default)
  end

  def set_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).includes(:stages).find(params[:id])
  end
end
