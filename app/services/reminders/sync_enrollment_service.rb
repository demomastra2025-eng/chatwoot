class Reminders::SyncEnrollmentService
  attr_reader :remindable

  def initialize(remindable:)
    @remindable = remindable
  end

  def perform
    if terminal_remindable?
      cancel_terminal_enrollments!
      return
    end

    enrollment_scope.active.find_each do |enrollment|
      enrollment.with_lock do
        enrollment.reload
        next unless enrollment.active?

        Reminders::EnrollmentScheduleService.new(enrollment: enrollment).refresh_next_due!
      end
    end
  end

  def cancel_before_destroy!
    cancel_terminal_enrollments!(reason: 'remindable_destroyed')
  end

  private

  def enrollment_scope
    TouchPlanEnrollment.where(remindable: remindable)
  end

  def terminal_remindable?
    return remindable.status.in?(%w[cancelled completed]) if remindable.is_a?(Scheduling::Appointment)
    return remindable.closed? || remindable.archived_at.present? if remindable.is_a?(Crm::Deal)

    true
  end

  def cancel_terminal_enrollments!(reason: 'remindable_terminal')
    enrollment_scope.where(status: %w[active completed]).find_each do |enrollment|
      cancelled_reminder = cancel_open_materialized_reminders(enrollment)
      next unless enrollment.active? || cancelled_reminder

      enrollment.cancel!(reason: reason, metadata: { synced_at: Time.current.iso8601 })
    end
  end

  def cancel_open_materialized_reminders(enrollment)
    cancelled = false
    enrollment.touch_occurrence_claims.includes(:reminder).find_each do |claim|
      reminder = claim.reminder
      next if reminder.blank? || Reminder::OPEN_STATUSES.exclude?(reminder.status)

      reminder.cancel!(reason_for_cancelled_reminder)
      cancelled ||= reminder.reload.cancelled?
      claim.update!(status: 'skipped', last_error: reason_for_cancelled_reminder) if reminder.cancelled?
    end
    cancelled
  end

  def reason_for_cancelled_reminder
    'cancelled because the source entity became terminal'
  end
end
