class TelegramPersonal::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'Telegram Personal'
  end

  def delivery_provider
    'telegram_personal'
  end

  def delivery_log_prefix
    'Telegram Personal'
  end
end
