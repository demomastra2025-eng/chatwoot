class Reminders::SyncMaterializedEnrollmentReminderService
  attr_reader :claim, :enrollment, :reminder, :step

  def initialize(enrollment:, claim:, reminder:, step:, lock: true)
    @enrollment = enrollment
    @claim = claim
    @reminder = reminder
    @step = step
    @lock = lock
  end

  def perform
    if @lock
      reminder.with_lock do
        sync_definition!
        sync_remindable!
      end
    else
      sync_definition!
      sync_remindable!
    end
    reminder.reload
  end

  private

  def sync_definition!
    reminder.reload
    return reminder if reminder.delivery_materialized? || Reminder::OPEN_STATUSES.exclude?(reminder.status)

    attributes = Reminders::EnrollmentReminderAttributes.new(
      enrollment: enrollment,
      step: step,
      claim: claim
    ).call
    reminder.assign_attributes(attributes)
    reminder.save! if reminder.changed?
  end

  def sync_remindable!
    source = enrollment.remindable
    return if source.blank?

    # Reconciliation may already hold Enrollment and Reminder in its transaction.
    # Never acquire Contact behind Reminder; a concurrent owner transfer holds Contact first.
    source = source.account.scheduling_appointments.find(source.id) if source.is_a?(Scheduling::Appointment)
    Reminders::SyncRemindableService.new(remindable: source, allow_processing: true)
                                    .perform_for(reminder, lock: false, raise_errors: true)
  end
end
