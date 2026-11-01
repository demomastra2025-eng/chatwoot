# frozen_string_literal: true

# Appointment callbacks and the release task use the same schedule refresh.
class Reminders::RetimeVisitTouchesService
  def initialize(appointment:)
    @appointment = appointment
  end

  def perform
    appointment.reminders.open_statuses.find_each do |reminder|
      retime_one(reminder)
    end
  end

  private

  attr_reader :appointment

  def retime_one(reminder)
    reminder.with_lock(requires_new: true) do
      retime_locked(reminder)
    end
  rescue StandardError => e
    Reminders::OperationDiagnostics.report(operation: 'retime_visit', error: e, record: appointment, touch: reminder)
    ChatwootExceptionTracker.new(e, account: appointment.account).capture_exception
  end

  def retime_locked(reminder)
    reminder.reload
    policy = Reminders::MissedAutomationTouchPolicy.new(reminder: reminder)
    return unless reminder.editable? && policy.automation_visit_touch?
    return if Current.medelement_reconciliation && !terminal_visit?
    return if refresh_and_cancel_short_lead!(reminder)

    policy.cancel_if_missed!
  end

  def refresh_and_cancel_short_lead!(reminder)
    return false if terminal_visit?

    schedule_stale = reminder.relative_schedule_stale?
    refresh_schedule(reminder)
    Reminders::AppointmentShortLeadCancellation.cancel_reminder_if_short!(reminder, rescheduled: schedule_stale)
  end

  def refresh_schedule(reminder)
    return unless reminder.relative_schedule_stale?

    reminder.scheduled_at_will_change!
    reminder.save!
  end

  def terminal_visit?
    appointment.status.in?(%w[completed no_show cancelled])
  end
end
