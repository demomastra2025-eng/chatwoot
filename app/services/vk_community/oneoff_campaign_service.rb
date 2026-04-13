class VkCommunity::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'VK'
  end

  def delivery_provider
    'vk_community'
  end

  def delivery_log_prefix
    'VK'
  end
end
