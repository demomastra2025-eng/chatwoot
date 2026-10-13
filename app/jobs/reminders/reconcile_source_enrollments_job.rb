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
    cancel_excluded_contact_touches(source)
  end

  private

  # The touches of a rule that are not tied to an enrollment are held to the rule's "Contact is not" list here.
  def cancel_excluded_contact_touches(source)
    return unless source.is_a?(AutomationRule)

    Reminders::CancelExcludedContactTouchesService.new(rule: source).perform
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: source.account).capture_exception
  end
end
