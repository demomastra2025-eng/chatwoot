# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'delete_campaign'
  end

  description 'Delete an account campaign that has not reached a terminal/running state'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    raise ArgumentError, 'Running campaigns must be cancelled before deletion' if campaign.running?

    payload = campaign_payload(campaign, include_config: false)
    campaign.destroy!

    formatted_payload(action: 'delete_campaign', deleted: true, campaign: payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
