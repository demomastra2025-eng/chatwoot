class Email::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def supported_inbox_types
    'Email'
  end

  def delivery_provider
    'email'
  end

  def delivery_log_prefix
    'Email'
  end
end
