class Campaigns::WindowedConversationOneoffService < Campaigns::ConversationOneoffService
  private

  def skip_contact_reason(contact)
    conversation = latest_conversation_for(contact)
    return 'Contact has no active reply window for this inbox' if conversation.blank? || !conversation.can_reply?

    super
  end

  def latest_conversation_for(contact)
    inbox.conversations
         .where(contact: contact)
         .joins(:messages)
         .where(messages: { message_type: Message.message_types[:incoming] })
         .distinct
         .order(last_activity_at: :desc)
         .first
  end
end
