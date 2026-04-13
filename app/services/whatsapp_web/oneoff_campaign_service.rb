class WhatsappWeb::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'WhatsApp Web'
  end

  def delivery_provider
    'whatsapp_web'
  end

  def delivery_log_prefix
    'WhatsApp Web'
  end
end
