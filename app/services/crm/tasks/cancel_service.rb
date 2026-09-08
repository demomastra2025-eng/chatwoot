class Crm::Tasks::CancelService < Crm::Tasks::CommandService
  private

  def event_type
    'task_cancelled'
  end

  def no_op?
    task.cancelled?
  end

  def apply_command!
    @was_cancelled = task.cancelled?
    reason = resolve_optional_text(:cancellation_reason, current: task.cancellation_reason)
    validation_error!('cancellation_reason', 'is required') if reason.blank?

    cancelled_outcome = task.task_type.outcomes.find_by(code: 'cancelled')
    apply_cancellation(reason, cancelled_outcome)
    transition_status!(active_status_for!('cancelled'))
  end

  def apply_cancellation(reason, cancelled_outcome)
    task.task_outcome = cancelled_outcome
    task.outcome = cancelled_outcome&.code
    task.outcome_note = nil
    task.completed_at = nil
    task.completed_by = nil
    task.cancelled_at ||= Time.zone.now
    task.cancelled_by = actor unless @was_cancelled
    task.cancellation_reason = reason
  end

  def command_event_type(_before_data)
    @was_cancelled ? 'task_status_changed' : event_type
  end
end
