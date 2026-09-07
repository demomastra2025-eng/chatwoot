class Crm::Tasks::UpsertService < Crm::BaseWriteService
  include Crm::Tasks::UpsertAttributes
  include Crm::Tasks::UpsertRelations

  def initialize(account:, params:, task: nil, actor: nil, **publication_options)
    @task = task || account.crm_tasks.new
    @broadcast_linked_deal = publication_options.fetch(:broadcast_linked_deal, true)
    @broadcast = publication_options.fetch(:broadcast, true)
    assert_known_publication_options!(publication_options)
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    new_record = task.new_record?
    saved_task = ApplicationRecord.transaction { persist_task!(new_record) }
    Crm::AfterCommit.run { publish_saved_task!(saved_task, new_record: new_record) } if @broadcast
    saved_task
  end

  private

  attr_reader :task, :broadcast_linked_deal

  def assert_known_publication_options!(options)
    unknown_options = options.keys - %i[broadcast broadcast_linked_deal]
    raise ArgumentError, "Unknown publication options: #{unknown_options.join(', ')}" if unknown_options.present?
  end

  def persist_task!(new_record)
    bootstrap_defaults!
    assert_lock_version!
    resolve_task_context!
    validate_task_references!
    task.assign_attributes(task_attributes(new_record))
    task.position = @requested_position if @requested_position.present?
    task.save!
    finalize_task!(new_record)
  end

  def resolve_task_context!
    @requested_position = resolve_requested_position
    @deal = resolve_optional_record(:deal_id, account.crm_deals, current: task.deal)
    @status = resolve_status!
    @task_type = resolve_task_type!
    @task_outcome = resolve_task_outcome(@task_type)
    @originating_conversation = resolve_originating_conversation(deal: @deal)
    @external_ref = resolve_optional_text(:external_ref, current: task.external_ref)
    @idempotency_key = resolve_optional_text(:idempotency_key, current: task.idempotency_key)
  end

  def validate_task_references!
    ensure_unique_reference!(
      scope: account.crm_tasks, attribute: :external_ref, value: @external_ref, code: 'DUPLICATE_EXTERNAL_REF'
    )
    ensure_unique_reference!(
      scope: account.crm_tasks, attribute: :idempotency_key, value: @idempotency_key, code: 'DUPLICATE_IDEMPOTENCY_KEY'
    )
  end

  def task_attributes(new_record)
    relationship_attributes
      .merge(content_attributes)
      .merge(schedule_attributes)
      .merge(reference_attributes)
      .merge(custom_attributes: resolved_custom_attributes(new_record))
  end

  def relationship_attributes
    {
      account: account,
      deal: @deal,
      status: @status,
      task_type: @task_type,
      task_outcome: @task_outcome,
      assignee: resolve_assignee(deal: @deal, originating_conversation: @originating_conversation),
      creator: resolve_optional_record(:creator_id, account.users, current: task.creator || actor),
      team: resolve_team(deal: @deal),
      originating_conversation: @originating_conversation
    }
  end

  def content_attributes
    {
      title: resolve_title,
      description: resolve_optional_text(:description, current: task.description),
      activity_type: @task_type.code,
      outcome: @task_outcome&.code,
      outcome_note: resolve_optional_text(:outcome_note, current: task.outcome_note),
      priority: resolve_optional_text(:priority, current: task.priority || 'medium')
    }
  end

  def schedule_attributes
    {
      all_day: resolve_all_day,
      due_on: resolve_due_on,
      schedule_timezone: resolve_schedule_timezone,
      start_at: resolve_datetime(:start_at, current: task.start_at),
      due_at: resolve_datetime(:due_at, current: task.due_at),
      completed_at: resolve_completed_at(status: @status)
    }
  end

  def reference_attributes
    { external_ref: @external_ref, idempotency_key: @idempotency_key }
  end

  def resolved_custom_attributes(new_record)
    field_catalog(deal: @deal).resolve_custom_attributes(
      current_attributes: task.custom_attributes,
      incoming_attributes: params[:custom_attributes],
      apply_defaults: new_record
    )
  end

  def finalize_task!(new_record)
    auto_apply_default_touch_plan! if new_record
    sync_related_touches!
    reposition_task!(@requested_position) if @requested_position.present?
    write_event!(new_record: new_record)
    notify_assignment!(new_record: new_record)
    task.reload
  end

  def publish_saved_task!(saved_task, new_record:)
    dispatch_crm_task_realtime_event!(
      new_record ? Events::Types::CRM_TASK_CREATED : Events::Types::CRM_TASK_UPDATED,
      saved_task,
      meta: { event_type: new_record ? 'task_created' : 'task_updated' }
    )
    dispatch_linked_deal_update!(saved_task, event_type: 'task_changed') if broadcast_linked_deal
  end

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform if account.feature_enabled?('crm_tasks')
  end

  def reposition_task!(requested_position)
    ::Crm::BoardPositioner.place!(
      scope: account.crm_tasks.kept.where(status_id: task.status_id),
      record: task,
      target_position: requested_position
    )
  end

  def write_event!(new_record:)
    return unless new_record || filtered_previous_changes.present?

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: task,
      actor: actor,
      event_type: new_record ? 'task_created' : 'task_updated',
      meta: { changes: filtered_previous_changes },
      command_key: new_record ? params[:idempotency_key] : nil
    )
  end

  def notify_assignment!(new_record:)
    return unless new_record || task.previous_changes.key?('assignee_id')

    ::Crm::AssignmentNotificationService.new(
      account: account,
      record: task,
      user: task.assignee,
      notification_type: 'task_assignment',
      actor: actor
    ).perform
  end

  def auto_apply_default_touch_plan!
    Reminders::DefaultPlanService.new(
      account: account,
      remindable: task,
      actor: actor
    ).perform
  end

  def sync_related_touches!
    Reminders::SyncRemindableService.new(remindable: task).perform
  end
end
