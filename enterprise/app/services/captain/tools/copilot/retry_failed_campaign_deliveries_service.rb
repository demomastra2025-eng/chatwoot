class Captain::Tools::Copilot::RetryFailedCampaignDeliveriesService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'retry_failed_campaign_deliveries'
  end

  description 'Retry failed deliveries for a campaign'
  param :campaign_id, type: :integer, desc: 'Campaign display ID', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    ::Campaigns::RetryFailedDeliveriesService.new(campaign: campaign).perform

    formatted_payload(::Campaigns::AnalyticsService.new(campaign: campaign.reload).call)
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
