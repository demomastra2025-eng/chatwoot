class Captain::Tools::Copilot::GetCampaignAnalyticsService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'get_campaign_analytics'
  end

  description 'Get analytics for a campaign'
  param :campaign_id, type: :integer, desc: 'Campaign display ID', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    formatted_payload(::Campaigns::AnalyticsService.new(campaign: campaign).call)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def find_campaign!(campaign_id)
    account.campaigns.find_by(display_id: campaign_id) || account.campaigns.find(campaign_id)
  end
end
