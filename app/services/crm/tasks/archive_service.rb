class Crm::Tasks::ArchiveService < Crm::BaseWriteService
  def initialize(account:, task:, params:, archived:, actor: nil)
    @task = task
    @archived = archived
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    saved_task, changed = ApplicationRecord.transaction { persist_archive_state! }
    publish_archive_state(saved_task) if changed
    saved_task
  end

  private

  attr_reader :task, :archived

  def persist_archive_state!
    task.lock!
    assert_lock_version!
    return [task, false] if archived == task.archived_at.present?

    task.update!(archived_at: archived ? Time.zone.now : nil)
    record_archive_event!
    [task.reload, true]
  end

  def record_archive_event!
    ::Crm::Events::Writer.record!(
      account: account,
      eventable: task,
      actor: actor,
      event_type: archive_event_type,
      meta: {},
      before_data: { archived_at: task.archived_at_before_last_save },
      after_data: { archived_at: task.archived_at }
    )
  end

  def publish_archive_state(saved_task)
    dispatch_crm_task_realtime_event!(realtime_event_type, saved_task, meta: { event_type: archive_event_type })
    dispatch_linked_deal_update!(saved_task, event_type: archive_event_type)
  end

  def archive_event_type
    archived ? 'task_archived' : 'task_unarchived'
  end

  def realtime_event_type
    archived ? Events::Types::CRM_TASK_ARCHIVED : Events::Types::CRM_TASK_UNARCHIVED
  end
end
