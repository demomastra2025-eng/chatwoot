class Api::V1::Accounts::Crm::TaskStatusesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :set_task_status, only: [:update, :destroy]

  def index
    authorize ::Crm::TaskStatus
    bootstrap_defaults!

    task_statuses = policy_scope(::Crm::TaskStatus).ordered
    render_payload(
      task_statuses.map { |task_status| ::Crm::PayloadBuilder.task_status(task_status) },
      meta: { count: task_statuses.size }
    )
  end

  def create
    authorize ::Crm::TaskStatus

    task_status = Current.account.crm_task_statuses.new(task_status_params)
    task_status.save!

    render_payload(::Crm::PayloadBuilder.task_status(task_status.reload), status: :created)
  end

  def update
    authorize @task_status
    @task_status.update!(task_status_params)

    render_payload(::Crm::PayloadBuilder.task_status(@task_status.reload))
  end

  def destroy
    authorize @task_status
    ensure_destroyable_task_status!
    @task_status.destroy!

    head :no_content
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def set_task_status
    @task_status = policy_scope(::Crm::TaskStatus).find(params[:id])
  end

  def task_status_params
    params.permit(:name, :code, :position, :category, :color, :active, :default)
  end

  def ensure_destroyable_task_status!
    return unless @task_status.tasks.exists?

    raise ::Crm::Error.new(
      code: 'TASK_STATUS_HAS_TASKS',
      message: 'You cannot delete a task status while it still has tasks. Move all open and completed tasks to another status first.',
      status: :unprocessable_content
    )
  end
end
