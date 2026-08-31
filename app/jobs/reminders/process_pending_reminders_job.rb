class Reminders::ProcessPendingRemindersJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    claimed_reminders = claim_due_reminders
    claimed_reminders.each_with_index do |(reminder, processing_claim), index|
      enqueue_execution!(reminder, processing_claim)
    rescue StandardError
      release_unenqueued_claims(claimed_reminders.drop(index))
      raise
    end
  end

  private

  def claim_due_reminders
    Reminder.transaction do
      reminders = Reminder.pending.due.lock('FOR UPDATE SKIP LOCKED').limit(BATCH_SIZE).to_a
      reminders.map { |reminder| [reminder, reminder.mark_processing!] }
    end
  end

  def release_unenqueued_claims(claimed_reminders)
    claimed_reminders.each do |reminder, processing_claim|
      reminder.release_processing_claim!(processing_claim)
    end
  end

  def enqueue_execution!(reminder, processing_claim)
    job = Reminders::ExecuteReminderJob.perform_later(reminder.id, processing_claim)
    return if job.successfully_enqueued?

    raise(job.enqueue_error || ActiveJob::EnqueueError.new('Reminder execution was not enqueued'))
  end
end
