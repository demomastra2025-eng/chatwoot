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
    @lock ? reminder.with_lock { sync_definition! } : sync_definition!

    if enrollment.remindable.present?
      Reminders::SyncRemindableService.new(remindable: enrollment.remindable, allow_processing: true)
                                      .perform_for(reminder, lock: @lock, raise_errors: true)
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
end
