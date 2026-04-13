class Line::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'LINE'
  end

  def delivery_provider
    'line'
  end

  def delivery_log_prefix
    'Line'
  end
end
