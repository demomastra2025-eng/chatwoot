class Crm::Tasks::StatusTransitionService < Crm::BaseWriteService
  def initialize(account:, task:, params:, actor: nil)
    @task = task
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      task.lock!
      assert_lock_version!

      target_status = account.crm_task_statuses.find(params[:status_id])
      return task if task.status_id == target_status.id

      from_status_id = task.status_id

      task.status = target_status
      task.completed_at = target_status.category_done? ? Time.zone.now : nil
      task.save!

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: task,
        actor: actor,
        event_type: 'task_status_changed',
        meta: {
          from_status_id: from_status_id,
          to_status_id: target_status.id
        }
      )

      task.reload
    end
  end

  private

  attr_reader :task
end
