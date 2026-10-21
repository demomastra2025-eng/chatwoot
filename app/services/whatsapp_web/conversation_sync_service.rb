class WhatsappWeb::ConversationSyncService
  pattr_initialize [:channel!, :contact_inbox!, { activity_at: nil }]

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
    current_contact_inbox_conversation = contact_inbox.conversations.order(last_activity_at: :desc, id: :desc).first
    latest_contact_conversation = channel.inbox.conversations.where(contact_id: contact_inbox.contact_id)
                                         .order(last_activity_at: :desc, id: :desc).first

    [current_contact_inbox_conversation, latest_contact_conversation].compact.max_by do |conversation|
      [conversation.last_activity_at, conversation.id]
    end
  end

  def sync_existing_conversation(conversation)
    updates = existing_conversation_updates(conversation)
    return conversation if updates.blank?

    conversation.update_columns(updates.merge(updated_at: Time.current))
    conversation
  end

  def existing_conversation_updates(conversation)
    updates = {}
    sync_existing_group_attributes!(updates, conversation) if group_contact_inbox?
    return updates if activity_at.blank?

    updates[:last_activity_at] = activity_at if conversation.last_activity_at.blank? || conversation.last_activity_at < activity_at
    updates[:agent_last_seen_at] = activity_at if conversation.agent_last_seen_at.blank?
    updates[:assignee_last_seen_at] = activity_at if conversation.assignee_last_seen_at.blank?
    updates
  end

  def sync_existing_group_attributes!(updates, conversation)
    current_attrs = (conversation.additional_attributes || {}).deep_stringify_keys
    merged_attrs = current_attrs.merge(group_additional_attributes)
    updates[:additional_attributes] = merged_attrs if merged_attrs != current_attrs
  end

  def create_conversation!
    timestamp = activity_at || Time.current
    additional_attrs = group_contact_inbox? ? group_additional_attributes : {}

    Conversation.new(
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      additional_attributes: additional_attrs,
      created_at: timestamp,
      updated_at: timestamp,
      last_activity_at: timestamp,
      agent_last_seen_at: timestamp,
      assignee_last_seen_at: timestamp
    ).tap do |conversation|
      conversation.skip_runtime_events = true
      conversation.save!
    end
  end

  def group_contact_inbox?
    contact_inbox.source_id.to_s.end_with?('@g.us')
  end

  def group_additional_attributes
    { 'is_group' => true, 'chat_type' => 'group' }
  end
end
