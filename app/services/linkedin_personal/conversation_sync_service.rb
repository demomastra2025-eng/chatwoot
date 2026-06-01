class LinkedinPersonal::ConversationSyncService
  pattr_initialize [:inbox!, :contact_inbox!, { activity_at: nil }, { additional_attributes: {} }]

  def perform
    existing_conversation = latest_contact_conversation
    return sync_existing_conversation(existing_conversation) if existing_conversation.present?

    contact_inbox.with_lock do
      existing_conversation = latest_contact_conversation
      return sync_existing_conversation(existing_conversation) if existing_conversation.present?

      create_conversation!
    end
  end

  private

  def latest_contact_conversation
    scope = inbox.lock_to_single_conversation ? contact_inbox.conversations : contact_inbox.conversations.where.not(status: :resolved)
    by_contact = if inbox.lock_to_single_conversation
                   inbox.conversations.where(contact_id: contact_inbox.contact_id)
                 else
                   inbox.conversations.where(contact_id: contact_inbox.contact_id).where.not(status: :resolved)
                 end
    [scope.order(last_activity_at: :desc, id: :desc).first,
     by_contact.order(last_activity_at: :desc, id: :desc).first].compact.max_by do |conversation|
      [conversation.last_activity_at || conversation.created_at, conversation.id]
    end
  end

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

  def create_conversation!
    timestamp = activity_at || Time.current
    Conversation.new(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      created_at: timestamp,
      updated_at: timestamp,
      last_activity_at: timestamp,
      additional_attributes: additional_attributes_payload
    ).tap do |conversation|
      conversation.skip_runtime_events = true
      conversation.save!
    end
  end

  def additional_attributes_payload
    additional_attributes.to_h.compact
  end
end
