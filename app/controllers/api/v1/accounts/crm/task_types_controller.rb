class Api::V1::Accounts::Crm::TaskTypesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :bootstrap_defaults!, only: :index
  before_action :set_task_type, only: [:update, :destroy]

  def index
    authorize ::Crm::TaskType
    task_types = policy_scope(::Crm::TaskType).includes(:outcomes).ordered
    render_payload(task_types.map { |task_type| ::Crm::PayloadBuilder.task_type(task_type) }, meta: { count: task_types.size })
  end

  def create
    authorize ::Crm::TaskType
    task_type = Current.account.crm_task_types.create!(task_type_params)
    render_payload(::Crm::PayloadBuilder.task_type(task_type.reload), status: :created)
  end

  def update
    authorize @task_type
    @task_type.update!(task_type_params)
    render_payload(::Crm::PayloadBuilder.task_type(@task_type.reload))
  end

  def destroy
    authorize @task_type
    ensure_destroyable!
    @task_type.destroy!
    head :no_content
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def set_task_type
    @task_type = policy_scope(::Crm::TaskType).find(params[:id])
  end

  def task_type_params
    params.permit(:name, :code, :icon, :position, :active, :default)
  end

  def ensure_destroyable!
    return unless @task_type.tasks.exists? || @task_type.outcomes.exists?

    raise ::Crm::Error.new(
      code: 'TASK_TYPE_IN_USE',
      message: 'Task type is in use and can only be archived',
      status: :unprocessable_content
    )
  end
end
