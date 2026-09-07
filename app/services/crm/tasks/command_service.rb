class Crm::Tasks::CommandService < Crm::BaseWriteService
  SNAPSHOT_KEYS = %w[
    status_id position task_type_id task_outcome_id outcome outcome_note assignee_id
    start_at due_at due_on all_day schedule_timezone completed_at completed_by_id
    cancelled_at cancelled_by_id cancellation_reason reschedule_count
  ].freeze

  def initialize(account:, task:, params:, actor: nil, **command_options)
    @task = task
    @correlation_id = command_options[:correlation_id]
    @broadcast = command_options.fetch(:broadcast, true)
    assert_known_command_options!(command_options)
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      task.lock!
      idempotent_task = find_idempotent_task
      next idempotent_task if idempotent_task

      assert_lock_version!
      if no_op? && !status_or_position_changed?
        record_noop_receipt! if params[:idempotency_key].present?
        next task
      end

      before_data = state_snapshot
      apply_command!
      task.save!
      after_save!
      record_command_event!(before_data)
      Crm::AfterCommit.run { publish_realtime!(task.reload) } if @broadcast
      task.reload
    end
  end

  private

  attr_reader :task

  def assert_known_command_options!(options)
    unknown_options = options.keys - %i[broadcast correlation_id]
    raise ArgumentError, "Unknown command options: #{unknown_options.join(', ')}" if unknown_options.present?
  end

  def no_op?
    false
  end

  def after_save!
    normalize_previous_status!
    if params[:position].present?
      Crm::BoardPositioner.place!(
        scope: account.crm_tasks.kept.where(status_id: task.status_id), record: task,
        target_position: resolve_integer(:position, current: task.position, allow_nil: true)
      )
    end
    Reminders::SyncRemindableService.new(remindable: task).perform
  end

  def record_command_event!(before_data)
    @recorded_event_type = command_event_type(before_data)
    Crm::Events::Writer.record!(
      account: account,
      eventable: task,
      actor: actor,
      event_type: @recorded_event_type,
      correlation_id: @correlation_id,
      command_key: params[:idempotency_key],
      meta: { command_type: event_type, command_fingerprint: command_fingerprint },
      before_data: before_data,
      after_data: state_snapshot
    )
  end

  def find_idempotent_task
    return if params[:idempotency_key].blank?

    event = task.events.find_by(command_key: params[:idempotency_key])
    return unless event

    original_type = event.meta['command_type'] || event.event_type
    return task.reload if original_type == event_type && event.meta['command_fingerprint'] == command_fingerprint

    raise Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used by another task command',
      status: :conflict,
      details: { idempotency_key: params[:idempotency_key] }
    )
  end

  def command_fingerprint
    @command_fingerprint ||= Digest::SHA256.hexdigest(fingerprint_payload.to_json)
  end

  def fingerprint_payload
    params.except(:lock_version, :idempotency_key).sort.to_h
  end

  def state_snapshot
    task.serializable_hash(only: SNAPSHOT_KEYS)
  end

  def active_status_for!(category, allowed: [category])
    statuses = account.crm_task_statuses.active
    status = params[:status_id].present? ? statuses.find(params[:status_id]) : statuses.find_by(category: category)
    return status if status && allowed.include?(status.category)

    validation_error!('status', "does not define an active #{category} state")
  end

  def status_or_position_changed?
    (params[:status_id].present? && params[:status_id].to_i != task.status_id) ||
      (params[:position].present? && params[:position].to_i != task.position)
  end

  def record_noop_receipt!
    Crm::Events::Writer.record!(
      account: account, eventable: task, actor: actor, event_type: 'task_command_noop',
      command_key: params[:idempotency_key], correlation_id: @correlation_id,
      meta: { command_type: event_type, command_fingerprint: command_fingerprint }
    )
  end

  def publish_realtime!(saved_task)
    dispatch_crm_task_realtime_event!(Events::Types::CRM_TASK_UPDATED, saved_task, meta: { event_type: @recorded_event_type })
    dispatch_linked_deal_update!(saved_task, event_type: @recorded_event_type)
  end

  def command_event_type(_before_data)
    event_type
  end

  def transition_status!(target_status)
    @from_status_id = task.status_id
    task.status = target_status
    return if @from_status_id == target_status.id

    task.position = target_status.tasks.kept.maximum(:position).to_i + 1
  end

  def normalize_previous_status!
    return if @from_status_id.blank? || @from_status_id == task.status_id

    Crm::BoardPositioner.normalize!(scope: account.crm_tasks.kept.where(status_id: @from_status_id))
  end

  def resolve_outcome!
    outcome = requested_outcome
    validation_error!('task_outcome_id', 'is required') if outcome.blank?
    validate_outcome!(outcome)
    outcome
  end

  def requested_outcome
    return account.crm_task_outcomes.find(params[:task_outcome_id]) if params[:task_outcome_id].present?
    return task.task_type.outcomes.find_by(code: params[:outcome].to_s.strip.downcase) if params[:outcome].present?

    current_or_default_outcome
  end

  def current_or_default_outcome
    return task.task_outcome if task.completed? && task.task_outcome.present?

    task.task_type.outcomes.active.find_by(default: true)
  end

  def validate_outcome!(outcome)
    validation_error!('task_outcome_id', 'does not belong to the selected task type') if outcome.task_type_id != task.task_type_id
    return if outcome.active? || outcome.id == task.task_outcome_id

    validation_error!('task_outcome_id', 'must be active')
  end
end
