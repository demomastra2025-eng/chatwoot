# frozen_string_literal: true

class Reminders::AutoCancelOnIncomingService
  CANCELLED_AFTER_INCOMING_REPLY = 'отменен после входящего ответа клиента'

  attr_reader :message

  def initialize(message:)
    @message = message
  end

  def perform
    return 0 unless customer_incoming_message?

    cancelled_count = 0
    cancellable_scope.find_each do |reminder|
      next unless explicitly_auto_cancelled?(reminder)

      reminder.cancel!(CANCELLED_AFTER_INCOMING_REPLY)
      cancelled_count += 1
    end
    cancelled_count
  end

  private

  def customer_incoming_message?
    message.present? && message.incoming? && !message.private? && !message.activity? && message.sender_type == 'Contact'
  end

  def cancellable_scope
    conversation = message.conversation
    message.account.reminders
           .open_statuses
           .where(auto_cancel_on_incoming: true)
           .where(
             'conversation_id = :conversation_id OR target_conversation_id = :conversation_id OR (remindable_type = :conversation_type AND remindable_id = :conversation_id)',
             conversation_id: conversation.id,
             conversation_type: 'Conversation'
           )
  end

  def explicitly_auto_cancelled?(reminder)
    Reminders::BooleanParam.truthy?(reminder.metadata.to_h['auto_cancel_on_incoming_explicit'])
  end
end
