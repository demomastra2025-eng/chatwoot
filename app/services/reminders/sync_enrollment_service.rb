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
    # A MedElement reconciliation of a past visit may close touches (above) but never refreshes the schedule of a running one.
    return if Current.medelement_reconciliation

    enrollment_scope.where(status: %w[active paused]).find_each do |enrollment|
      sync_open_enrollment(enrollment)
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
    return remindable.status.in?(%w[cancelled completed no_show]) if remindable.is_a?(Scheduling::Appointment)
    return remindable.closed? || remindable.archived_at.present? if remindable.is_a?(Crm::Deal)

    true
  end

  def cancel_terminal_enrollments!(reason: 'remindable_terminal')
    enrollment_scope.where(status: %w[active paused completed]).find_each do |enrollment|
      next if enrollment.metadata['allow_terminal_at_activation']

      cancelled_reminder = cancel_open_materialized_reminders(enrollment)
      next unless enrollment.active? || enrollment.paused? || cancelled_reminder

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

  def sync_open_enrollment(enrollment)
    enrollment.with_lock do
      enrollment.reload
      next unless enrollment.active? || enrollment.paused?

      clear_terminal_at_activation!(enrollment)
      previous_due_at = enrollment.next_due_at
      Reminders::EnrollmentScheduleService.new(enrollment: enrollment).refresh_next_due!
      rescheduled = appointment_rescheduled?(previous_due_at, enrollment.next_due_at)
      Reminders::AppointmentShortLeadCancellation.cancel_enrollment_if_short!(enrollment, rescheduled: rescheduled)
    end
  end

  def appointment_rescheduled?(previous_due_at, current_due_at)
    return false unless remindable.is_a?(Scheduling::Appointment)

    remindable.saved_change_to_starts_at? ||
      remindable.previous_changes.key?('starts_at') ||
      (previous_due_at.present? && current_due_at != previous_due_at)
  end

  def clear_terminal_at_activation!(enrollment)
    return unless enrollment.metadata['allow_terminal_at_activation']

    enrollment.update!(metadata: enrollment.metadata.except('allow_terminal_at_activation'))
  end
end
