class Reminders::ReconcileSourceEnrollmentsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(source_type, source_id)
    source = source_type.safe_constantize&.find_by(id: source_id)
    return if source.blank?

    source.touch_plan_enrollments.where(status: %w[active paused completed]).find_each do |enrollment|
      Reminders::ReconcileEnrollmentService.new(enrollment: enrollment).perform
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: enrollment.account).capture_exception
    end
  end
end
