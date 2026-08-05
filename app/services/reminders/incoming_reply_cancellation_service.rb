# frozen_string_literal: true

class Reminders::IncomingReplyCancellationService
  CANCEL_REASON = 'отменен после входящего ответа клиента'
  CANCELLED_VIA_KEY = 'cancelled_via'
  CANCELLED_BY_MESSAGE_ID_KEY = 'cancelled_by_message_id'
  CANCELLED_AT_KEY = 'incoming_reply_cancelled_at'

  attr_reader :message, :reminder

  def self.customer_incoming_message?(message)
    message.present? && message.incoming? && !message.private? && !message.activity? && message.sender_type == 'Contact'
  end

  def initialize(reminder:, message:)
    @reminder = reminder
    @message = message
  end

  def perform
    return false unless self.class.customer_incoming_message?(message)

    reminder.with_lock do
      reminder.reload
      next false unless cancellable?

      cancelled_at = Time.current
      reminder.update!(
        status: :cancelled,
        cancelled_at: cancelled_at,
        last_error: CANCEL_REASON,
        processing_started_at: nil,
        metadata: reminder.metadata.to_h.merge(
          CANCELLED_VIA_KEY => 'incoming_reply',
          CANCELLED_BY_MESSAGE_ID_KEY => message.id,
          CANCELLED_AT_KEY => cancelled_at.iso8601(6)
        )
      )
      log_cancellation
      true
    end
  end

  private

  def cancellable?
    Reminder::OPEN_STATUSES.include?(reminder.status) &&
      !reminder.delivery_materialized? &&
      Reminders::BooleanParam.truthy?(reminder.metadata.to_h['auto_cancel_on_incoming_explicit'])
  end

  def log_cancellation
    Rails.logger.info(
      event: 'reminder_auto_cancelled_on_incoming',
      account_id: reminder.account_id,
      conversation_id: message.conversation_id,
      reminder_id: reminder.id,
      incoming_message_id: message.id,
      trigger_message_id: reminder.metadata.to_h[Reminder::AUTOMATION_TRIGGER_MESSAGE_ID_KEY]
    )
  end
end
