class TelegramPersonal::ConversationSyncService
  pattr_initialize [:inbox!, :contact_inbox!, { activity_at: nil }, { additional_attributes: {} }]

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
    updates = {}
    updates[:last_activity_at] = activity_at if activity_at.present? &&
                                                (conversation.last_activity_at.blank? || conversation.last_activity_at < activity_at)

    merged_attributes = (conversation.additional_attributes || {}).merge(additional_attributes_payload)
    updates[:additional_attributes] = merged_attributes if merged_attributes != conversation.additional_attributes

    return conversation if updates.blank?

    conversation.update!(updates)
    conversation
  end

  def conversation_attributes
    timestamp = activity_at || Time.current

    {
      created_at: timestamp,
      updated_at: timestamp,
      last_activity_at: timestamp,
      additional_attributes: additional_attributes_payload,
      skip_runtime_events: true
    }
  end

  def additional_attributes_payload
    additional_attributes.to_h.compact
  end
end
