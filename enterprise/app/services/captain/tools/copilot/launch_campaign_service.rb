# frozen_string_literal: true

class Captain::Tools::Copilot::LaunchCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'launch_campaign'
  end

  description 'Launch an active one-off outbound campaign after preview safety checks'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true

  def execute(campaign_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    preview = campaign_preview(campaign)
    ensure_launchable!(campaign, preview)
    ::Campaigns::TriggerOneoffCampaignJob.perform_later(campaign)

    formatted_payload(
      action: 'launch_campaign',
      queued: true,
      campaign: campaign_payload(campaign.reload, include_config: false),
      preview: preview
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
