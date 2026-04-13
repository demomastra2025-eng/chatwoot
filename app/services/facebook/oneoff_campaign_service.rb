class Facebook::OneoffCampaignService < Campaigns::WindowedConversationOneoffService
  private

  def supported_inbox_types
    'Facebook'
  end

  def delivery_provider
    'facebook'
  end

  def delivery_log_prefix
    'Facebook'
  end
end
