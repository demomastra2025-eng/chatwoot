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
      reminders.filter_map { |reminder| claim_reminder(reminder) }
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

  def claim_reminder(reminder)
    [reminder, reminder.mark_processing!]
  rescue ActiveRecord::RecordInvalid => e
    quarantine_invalid_reminder!(reminder, e)
    nil
  end

  def quarantine_invalid_reminder!(reminder, error)
    validation_message = error.record.errors.full_messages.to_sentence
    reminder.reload
    # The record is already invalid, so normal validation cannot persist its terminal quarantine state.
    # rubocop:disable Rails/SkipsModelValidations
    reminder.update_columns(
      status: Reminder.statuses.fetch('failed'),
      processing_started_at: nil,
      last_error: validation_message,
      attempts_count: reminder.attempts_count.to_i + 1,
      metadata: reminder.metadata.to_h.except(*Reminder::TRANSIENT_METADATA_KEYS),
      updated_at: Time.current
    )
    # rubocop:enable Rails/SkipsModelValidations
    Rails.logger.error(
      "[REMINDERS] quarantined invalid reminder id=#{reminder.id} " \
      "account_id=#{reminder.account_id} errors=#{validation_message}"
    )
  end
end
