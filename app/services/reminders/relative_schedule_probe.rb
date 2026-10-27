# frozen_string_literal: true

class Reminders::RelativeScheduleProbe
  def initialize(account:, remindable:, definition:, created_at:)
    @account = account
    @remindable = remindable
    @definition = definition.with_indifferent_access
    @created_at = created_at
  end

  def reminder
    @reminder ||= begin
      probe = Reminder.new(
        account: @account,
        remindable: @remindable,
        status: :pending,
        metadata: { 'touch_source' => 'automation' },
        timing_mode: @definition[:timing_mode],
        relative_anchor: @definition[:relative_anchor],
        relative_offset_seconds: @definition[:relative_offset_seconds],
        relative_time_mode: @definition[:relative_time_mode],
        relative_time_of_day: @definition[:relative_time_of_day],
        timezone: @definition[:timezone].presence || 'UTC'
      )
      probe.created_at = @created_at
      probe.send(:materialize_schedule)
      probe
    end
  end

  def due_at
    reminder.scheduled_at
  end
end
