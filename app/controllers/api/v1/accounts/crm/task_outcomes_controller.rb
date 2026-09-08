class Api::V1::Accounts::Crm::TaskOutcomesController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :bootstrap_defaults!, only: :index
  before_action :set_task_outcome, only: [:update, :destroy]

  def index
    authorize ::Crm::TaskOutcome
    outcomes = policy_scope(::Crm::TaskOutcome).includes(:task_type).ordered
    outcomes = outcomes.where(task_type_id: params[:task_type_id]) if params[:task_type_id].present?
    render_payload(outcomes.map { |outcome| ::Crm::PayloadBuilder.task_outcome(outcome) }, meta: { count: outcomes.size })
  end

  def create
    authorize ::Crm::TaskOutcome
    task_type = Current.account.crm_task_types.find(task_outcome_params[:task_type_id])
    outcome = task_type.outcomes.create!(task_outcome_params.except(:task_type_id).merge(account: Current.account))
    render_payload(::Crm::PayloadBuilder.task_outcome(outcome.reload), status: :created)
  end

  def update
    authorize @task_outcome
    attributes = task_outcome_params.except(:task_type_id)
    @task_outcome.update!(attributes)
    render_payload(::Crm::PayloadBuilder.task_outcome(@task_outcome.reload))
  end

  def destroy
    authorize @task_outcome
    ensure_destroyable!
    @task_outcome.destroy!
    head :no_content
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def set_task_outcome
    @task_outcome = policy_scope(::Crm::TaskOutcome).find(params[:id])
  end

  def task_outcome_params
    params.permit(:task_type_id, :name, :code, :position, :active, :default, :requires_note)
  end

  def ensure_destroyable!
    return unless @task_outcome.tasks.exists?

    raise ::Crm::Error.new(
      code: 'TASK_OUTCOME_IN_USE',
      message: 'Task outcome is in use and can only be archived',
      status: :unprocessable_content
    )
  end
end
