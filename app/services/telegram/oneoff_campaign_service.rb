class Telegram::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'Telegram'
  end

  def delivery_provider
    'telegram'
  end

  def delivery_log_prefix
    'Telegram'
  end

  def conversation_attributes(contact:, target_identifier:)
    latest_attributes = latest_conversation_attributes(contact)
    latest_attributes[:chat_id] ||= target_identifier
    latest_attributes
  end

  def latest_conversation_attributes(contact)
    latest_conversation = inbox.conversations.where(contact: contact).order(last_activity_at: :desc).first
    (latest_conversation&.additional_attributes || {}).slice('chat_id', 'business_connection_id').symbolize_keys
  end
end
