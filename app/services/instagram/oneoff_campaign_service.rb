class Instagram::OneoffCampaignService < Campaigns::WindowedConversationOneoffService
  private

  def supported_inbox_types
    'Instagram'
  end

  def delivery_provider
    'instagram'
  end

  def delivery_log_prefix
    'Instagram'
  end
end
