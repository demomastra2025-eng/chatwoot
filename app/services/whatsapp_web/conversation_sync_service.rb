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
    return conversation if activity_at.blank?
    return conversation if conversation.last_activity_at.present? && conversation.last_activity_at >= activity_at

    conversation.update_columns(last_activity_at: activity_at, updated_at: Time.current)
    conversation
  end

  def create_conversation!
    timestamp = activity_at || Time.current

    Conversation.new(
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      created_at: timestamp,
      updated_at: timestamp,
      last_activity_at: timestamp
    ).tap do |conversation|
      conversation.skip_runtime_events = true
      conversation.save!
    end
  end
end
