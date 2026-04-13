class Tiktok::OneoffCampaignService < Campaigns::WindowedConversationOneoffService
  private

  def supported_inbox_types
    'Tiktok'
  end

  def delivery_provider
    'tiktok'
  end

  def delivery_log_prefix
    'Tiktok'
  end

  def conversation_attributes(contact:, target_identifier:)
    latest_attributes = latest_conversation_attributes(contact)
    latest_attributes[:conversation_id] ||= target_identifier
    latest_attributes
  end

  def latest_conversation_attributes(contact)
    latest_conversation = inbox.conversations.where(contact: contact).order(last_activity_at: :desc).first
    (latest_conversation&.additional_attributes || {}).slice('conversation_id').symbolize_keys
  end
end
