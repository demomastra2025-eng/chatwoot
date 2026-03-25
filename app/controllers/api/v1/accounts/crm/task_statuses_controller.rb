class Api::V1::Accounts::Crm::TaskStatusesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :bootstrap_defaults!, only: [:index]
  before_action :set_task_status, only: [:update]

  def index
    authorize ::Crm::TaskStatus

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

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def set_task_status
    @task_status = policy_scope(::Crm::TaskStatus).find(params[:id])
  end

  def task_status_params
    params.permit(:name, :code, :position, :category, :active, :default)
  end
end
