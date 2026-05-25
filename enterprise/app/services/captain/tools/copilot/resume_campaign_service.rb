# frozen_string_literal: true

class Captain::Tools::Copilot::ResumeCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'resume_campaign'
  end

  description 'Resume remaining recipients for a failed or cancelled one-off campaign run'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    ::Campaigns::ResumeService.new(campaign: campaign).perform

    formatted_payload(
      action: 'resume_campaign',
      campaign: campaign_payload(campaign.reload, include_config: false),
      analytics: ::Campaigns::AnalyticsService.new(campaign: campaign.reload).call
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
