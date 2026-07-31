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
    requested_at = Time.current
    enqueue_created = campaign.request_one_off_launch!(requested_at: requested_at)
    enqueue_campaign(campaign, requested_at: requested_at) if enqueue_created

    formatted_payload(
      action: 'launch_campaign',
      queued: true,
      enqueue_created: enqueue_created,
      idempotent_replay: !enqueue_created,
      campaign: campaign_payload(campaign.reload, include_config: false),
      preview: preview
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def enqueue_campaign(campaign, requested_at:)
    ::Campaigns::TriggerOneoffCampaignJob.perform_later(campaign)
  rescue StandardError
    campaign.release_one_off_launch!(requested_at: requested_at)
    raise
  end
end
