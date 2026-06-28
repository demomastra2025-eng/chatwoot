class ParticipationListener < BaseListener
  include Events::Types

  def assignee_changed(event)
    conversation, _account = extract_conversation_and_account(event)
    return if conversation.assignee_id.blank?

    ConversationParticipant.find_or_create_for!(conversation: conversation, user_id: conversation.assignee_id)
  # We have observed race conditions triggering these errors
  # example: Assignment happening via automation, while auto assignment is also configured.
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Rails.logger.warn "Failed to create conversation participant for account #{conversation.account.id} " \
                      ": user #{conversation.assignee_id} : conversation #{conversation.id}"
  end
end
