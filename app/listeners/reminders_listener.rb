class RemindersListener < BaseListener
  CANCELLED_AFTER_INCOMING_REPLY = 'Cancelled after incoming reply'.freeze

  def message_created(event)
    message = event.data[:message]

    return if message.blank?
    return unless message.incoming?
    return if message.private? || message.activity?

    cancel_matching_touches(message)
  end

  private

  def cancel_matching_touches(message)
    conversation = message.conversation
    scope = message.account.reminders
                   .open_statuses
                   .where(auto_cancel_on_incoming: true, target_inbox_id: conversation.inbox_id)
                   .where(
                     'conversation_id = :conversation_id OR target_conversation_id = :conversation_id OR target_contact_inbox_id = :contact_inbox_id OR target_contact_id = :contact_id',
                     conversation_id: conversation.id,
                     contact_inbox_id: conversation.contact_inbox_id,
                     contact_id: conversation.contact_id
                   )

    scope.find_each do |touch|
      touch.cancel!(CANCELLED_AFTER_INCOMING_REPLY)
    end
  end
end
