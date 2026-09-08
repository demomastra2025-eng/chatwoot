class Crm::Tasks::ArchiveService < Crm::BaseWriteService
  def initialize(account:, task:, params:, archived:, actor: nil)
    @task = task
    @archived = archived
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    changed = false
    saved_task = ApplicationRecord.transaction do
      task.lock!
      assert_lock_version!

      next task if archived == task.archived_at.present?

      changed = true
      archived_at = archived ? Time.zone.now : nil
      task.update!(archived_at: archived_at)

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: task,
        actor: actor,
        event_type: archived ? 'task_archived' : 'task_unarchived',
        meta: {},
        before_data: { archived_at: task.archived_at_before_last_save },
        after_data: { archived_at: task.archived_at }
      )

      task.reload
    end
    if changed
      dispatch_crm_task_realtime_event!(
        archived ? Events::Types::CRM_TASK_ARCHIVED : Events::Types::CRM_TASK_UNARCHIVED,
        saved_task,
        meta: { event_type: archived ? 'task_archived' : 'task_unarchived' }
      )
      dispatch_linked_deal_update!(saved_task, event_type: archived ? 'task_archived' : 'task_unarchived')
    end
    saved_task
  end

  private

  attr_reader :task, :archived
end
