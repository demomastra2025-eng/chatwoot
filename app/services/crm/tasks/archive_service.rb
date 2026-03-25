class Crm::Tasks::ArchiveService < Crm::BaseWriteService
  def initialize(account:, task:, params:, archived:, actor: nil)
    @task = task
    @archived = archived
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      task.lock!
      assert_lock_version!

      return task if archived == task.archived_at.present?

      archived_at = archived ? Time.zone.now : nil
      task.update!(archived_at: archived_at)

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: task,
        actor: actor,
        event_type: archived ? 'task_archived' : 'task_unarchived',
        meta: {}
      )

      task.reload
    end
  end

  private

  attr_reader :task, :archived
end
