class Reminders::CancelEnrollmentService
  attr_reader :enrollment, :metadata, :reason

  def initialize(enrollment:, reason:, metadata: {})
    @enrollment = enrollment
    @reason = reason
    @metadata = metadata
  end

  def perform
    enrollment.with_lock do
      enrollment.reload
      cancelled_open_reminder = cancel_open_reminders!
      preserve_completed = enrollment.completed? && !cancelled_open_reminder
      enrollment.cancel!(reason: reason, metadata: metadata) unless preserve_completed || enrollment.cancelled?
    end
    enrollment
  end

  private

  def cancel_open_reminders!
    cancelled = false
    enrollment.touch_occurrence_claims.includes(:reminder).find_each do |claim|
      reminder = claim.reminder
      next if reminder.blank? || Reminder::OPEN_STATUSES.exclude?(reminder.status)
      next if reminder.delivery_materialized?

      reminder.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        processing_started_at: nil,
        last_error: reason
      )
      claim.update!(status: 'skipped', last_error: reason)
      cancelled = true
    end
    cancelled
  end
end
