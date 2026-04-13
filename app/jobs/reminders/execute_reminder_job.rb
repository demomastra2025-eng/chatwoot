class Reminders::ExecuteReminderJob < ApplicationJob
  queue_as :high

  discard_on ActiveRecord::RecordNotFound

  def perform(reminder_id)
    reminder = Reminder.find(reminder_id)
    return unless reminder.processing?

    Reminders::ExecuteService.new(reminder: reminder).perform
  end
end
