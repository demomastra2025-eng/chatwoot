class WhatsappWeb::ConversationSyncService
  pattr_initialize [:channel!, :contact_inbox!, { activity_at: nil }]

  def perform
    sync_existing_conversation(
      Conversations::IdentityResolver.resolve_primary!(
        contact_inbox: contact_inbox,
        attributes: conversation_attributes
      )
    )
  end

  private

  def sync_existing_conversation(conversation)
    return conversation if activity_at.blank? &&
                           conversation.agent_last_seen_at.present? &&
                           conversation.assignee_last_seen_at.present?

    updates = {}
    updates[:last_activity_at] = activity_at if activity_at.present? &&
                                                (conversation.last_activity_at.blank? || conversation.last_activity_at < activity_at)
    updates[:agent_last_seen_at] = activity_at if activity_at.present? && conversation.agent_last_seen_at.blank?
    updates[:assignee_last_seen_at] = activity_at if activity_at.present? && conversation.assignee_last_seen_at.blank?
    return conversation if updates.blank?

    conversation.update_columns(updates.merge(updated_at: Time.current))
    conversation
  end

  def conversation_attributes
    timestamp = activity_at || Time.current

    {
      created_at: timestamp,
      updated_at: timestamp,
      last_activity_at: timestamp,
      agent_last_seen_at: timestamp,
      assignee_last_seen_at: timestamp,
      skip_runtime_events: true
    }
  end
end
