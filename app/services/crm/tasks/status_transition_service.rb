class Crm::Tasks::StatusTransitionService < Crm::BaseWriteService
  def initialize(account:, task:, params:, actor: nil)
    @task = task
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    target_status = account.crm_task_statuses.find(params[:status_id])
    service_class = case target_status.category
                    when 'done' then Crm::Tasks::CompleteService
                    when 'cancelled' then Crm::Tasks::CancelService
                    else Crm::Tasks::ReopenService
                    end
    service_class.new(account: account, task: task, actor: actor, params: params).perform
  end

  private

  attr_reader :task
end
