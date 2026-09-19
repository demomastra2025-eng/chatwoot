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
