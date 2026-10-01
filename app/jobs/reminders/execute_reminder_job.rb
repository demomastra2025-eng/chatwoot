class Reminders::ExecuteReminderJob < ApplicationJob
  queue_as :reminders

  discard_on ActiveRecord::RecordNotFound
  discard_on Reminders::UndeliverableTargetError

  def perform(reminder_id, processing_claim = nil)
    reminder = Reminder.find(reminder_id)
    return unless reminder.processing?
    return unless current_claim?(reminder, processing_claim)

    Reminders::ExecuteService.new(reminder: reminder, processing_claim: processing_claim).perform
  end

  private

  # A retried completion also runs when the touch's delivery already dispatched the message and consumed the claim
  # (Reminders::ExecutionFinisher.dispatched_before_completion?): it only completes the touch.
  def current_claim?(reminder, processing_claim)
    current_claim = reminder.processing_claim_token
    return current_claim.blank? if processing_claim.blank?

    current_claim == processing_claim || Reminders::ExecutionFinisher.dispatched_before_completion?(reminder)
  end
end
