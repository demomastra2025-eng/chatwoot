class Reminders::ProcessPendingRemindersJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    claim_due_reminders.each do |reminder|
      Reminders::ExecuteReminderJob.perform_later(reminder.id)
    end
  end

  private

  def claim_due_reminders
    Reminder.transaction do
      reminders = Reminder.pending.due.lock('FOR UPDATE SKIP LOCKED').limit(BATCH_SIZE).to_a
      reminders.each(&:mark_processing!)
      reminders
    end
  end
end
