class Messages::StatusUpdateService
  attr_reader :message, :status, :external_error

  def initialize(message, status, external_error = nil)
    @message = message
    @status = status
    @external_error = external_error
  end

  def perform
    return false unless valid_status_transition?

    update_message_status
  end

  private

  def update_message_status
    # Update status and set external_error only when failed
    message.update!(
      status: status,
      external_error: (status == 'failed' ? external_error : nil)
    )
    update_touch_delivery_status
  end

  def update_touch_delivery_status
    touch_id = message.additional_attributes.to_h['touch_id']
    return if touch_id.blank?

    reminder = Reminder.find_by(id: touch_id, account_id: message.account_id)
    return if reminder.blank?

    reminder.record_delivery_status!(
      message_id: message.id,
      stage: touch_delivery_stage,
      error: external_error
    )
    schedule_confirmed_captain_follow_up(reminder)
  end

  def schedule_confirmed_captain_follow_up(reminder)
    return unless reminder.captain_follow_up? && reminder.delivery_dispatched_for?(message.id)
    return unless touch_delivery_stage.in?(%w[provider_accepted delivered read])

    Captain::Conversation::FollowUpJob.schedule_after_delivery!(reminder: reminder, message: message)
  rescue *Reminders::ExecuteService::TRANSIENT_DATABASE_ERRORS => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Retrying confirmed next-step scheduling: #{e.class.name}")
    raise LockAcquisitionError, 'Could not persist a confirmed Captain follow-up next step'
  end

  def touch_delivery_stage
    return 'template_rejected' if status == 'failed' && external_error.to_s.match?(/template|шаблон/i)
    return 'failed' if status == 'failed'
    return 'read' if status == 'read'
    return 'delivered' if status == 'delivered'

    'provider_accepted'
  end

  def valid_status_transition?
    return false unless Message.statuses.key?(status)

    # Don't allow changing from 'read' to 'delivered'
    return false if message.read? && status == 'delivered'

    true
  end
end
