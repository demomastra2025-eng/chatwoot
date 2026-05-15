# frozen_string_literal: true

class Captain::Tools::Copilot::CancelCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'cancel_campaign'
  end

  description 'Cancel an active or running one-off campaign in the current account'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    campaign.cancel_one_off!

    formatted_payload(action: 'cancel_campaign', campaign: campaign_payload(campaign.reload, include_config: false))
  rescue StandardError => e
    tool_failure(e)
  end
end
