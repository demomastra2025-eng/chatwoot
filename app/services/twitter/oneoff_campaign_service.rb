class Twitter::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'Twitter'
  end

  def delivery_provider
    'twitter'
  end

  def delivery_log_prefix
    'Twitter'
  end

  def skip_contact_reason(contact)
    return 'Contact does not have an existing Twitter direct-message thread.' if latest_direct_message_conversation(contact).blank?

    super
  end

  def conversation_attributes(contact:, target_identifier:)
    latest_attributes = latest_conversation_attributes(contact)
    latest_attributes[:type] ||= 'direct_message'
    latest_attributes
  end

  def latest_conversation_attributes(contact)
    (latest_direct_message_conversation(contact)&.additional_attributes || {}).slice('type').symbolize_keys
  end

  def latest_direct_message_conversation(contact)
    inbox.conversations.where(contact: contact).where("additional_attributes ->> 'type' = ?", 'direct_message').order(last_activity_at: :desc).first
  end
end
