# frozen_string_literal: true

class Captain::Tools::Copilot::GetCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'get_campaign'
  end

  description 'Get one account campaign with configuration and latest run metadata'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    formatted_payload(action: 'get_campaign', campaign: campaign_payload(campaign, include_config: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
