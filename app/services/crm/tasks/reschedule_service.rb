class Crm::Tasks::RescheduleService < Crm::Tasks::CommandService
  SCHEDULE_KEYS = %i[all_day due_on due_at start_at schedule_timezone].freeze

  private

  def event_type
    'task_rescheduled'
  end

  def apply_command!
    validate_reschedule_request!
    before = schedule_snapshot
    all_day = resolved_all_day
    task.assign_attributes(schedule_attributes(all_day))
    validation_error!('schedule', 'must change the current schedule') if before == schedule_snapshot

    task.reschedule_count += 1
  end

  def validate_reschedule_request!
    validation_error!('schedule', 'must include a schedule change') unless SCHEDULE_KEYS.any? { |key| params.key?(key) }
    validation_error!('task', 'must be open to reschedule') if task.completed? || task.cancelled?
  end

  def schedule_attributes(all_day)
    {
      all_day: all_day,
      due_on: resolved_due_on(all_day),
      due_at: resolved_due_at(all_day),
      start_at: all_day ? nil : resolve_datetime(:start_at, current: task.start_at),
      schedule_timezone: resolved_schedule_timezone
    }
  end

  def resolved_schedule_timezone
    resolve_optional_text(
      :schedule_timezone,
      current: task.schedule_timezone || account.workspace_working_hours_timezone
    )
  end

  def resolved_all_day
    return ActiveModel::Type::Boolean.new.cast(params[:all_day]) if params.key?(:all_day)
    return true if params.key?(:due_on) && params[:due_on].present?
    return false if params.key?(:due_at)

    task.all_day
  end

  def resolved_due_on(all_day)
    return unless all_day
    return resolve_date(:due_on, current: task.due_on) if params.key?(:due_on)
    return task.due_at&.in_time_zone(task.schedule_timezone)&.to_date if params.key?(:all_day) && task.due_on.blank?

    task.due_on
  end

  def resolved_due_at(all_day)
    return if all_day
    return resolve_datetime(:due_at, current: task.due_at) if params.key?(:due_at)

    task.due_at
  end

  def schedule_snapshot
    {
      all_day: task.all_day,
      start_at: task.start_at&.iso8601,
      due_at: task.due_at&.iso8601,
      due_on: task.due_on&.iso8601,
      schedule_timezone: task.schedule_timezone
    }
  end
end
