class LinkedinPersonal::OneoffCampaignService < Campaigns::ConversationOneoffService
  private

  def provider
    'linkedin_personal'
  end
end
