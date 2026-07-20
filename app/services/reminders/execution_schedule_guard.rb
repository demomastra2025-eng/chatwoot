class Reminders::ExecutionScheduleGuard
  CONTINUE = :continue
  STOP = :stop
  MISSED_RELATIVE_SCHEDULE = 'Skipped relative touch because its scheduled time had already passed when it was created.'.freeze

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return CONTINUE unless refreshable?

    reminder.remindable.reload
    refresh_schedule_if_anchor_changed!
    return stop_for_missed_schedule! if missed_relative_schedule?
    return stop_for_rescheduled_touch! if reminder.scheduled_at&.future?

    CONTINUE
  end

  private

  attr_reader :reminder

  def refreshable?
    reminder.relative? && reminder.remindable.present? && !reminder.manual_schedule_override?
  end

  def refresh_schedule_if_anchor_changed!
    anchor_time = reminder.send(:relative_anchor_time)
    return if same_time?(anchor_time, reminder.last_materialized_anchor_at)

    reminder.save!
  end

  def missed_relative_schedule?
    reminder.scheduled_at.present? && reminder.created_at.present? && reminder.scheduled_at < reminder.created_at
  end

  def stop_for_missed_schedule!
    reminder.update!(
      status: :cancelled,
      cancelled_at: Time.current,
      processing_started_at: nil,
      last_error: MISSED_RELATIVE_SCHEDULE
    )
    STOP
  end

  def stop_for_rescheduled_touch!
    reminder.update!(status: :pending, processing_started_at: nil)
    STOP
  end

  def same_time?(left, right)
    return true if left.blank? && right.blank?

    left.present? && right.present? && left.to_i == right.to_i
  end
end
