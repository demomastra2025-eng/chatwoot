module Campaigns::ToolPayloadBuilder
  module_function

  def list_payload(filters:, total_count:, campaigns:)
    {
      action: 'list_campaigns',
      filters: filters,
      total_count: total_count,
      campaigns: campaigns.map { |campaign| campaign_payload(campaign) }
    }.compact
  end

  def campaign_payload(campaign)
    {
      id: campaign.display_id,
      campaign_id: campaign.display_id,
      title: campaign.title,
      description: campaign.description,
      inbox_id: campaign.inbox_id,
      inbox_name: campaign.inbox&.name,
      sender_id: campaign.sender_id,
      sender_name: campaign.sender&.name,
      campaign_status: campaign.campaign_status,
      campaign_type: campaign.campaign_type,
      enabled: campaign.enabled,
      message: campaign.message,
      instructions: campaign.instructions,
      text_mode: campaign.text_mode,
      scheduled_at: campaign.scheduled_at&.iso8601,
      updated_at: campaign.updated_at&.iso8601,
      latest_run: latest_run_payload(campaign.latest_campaign_run)
    }.compact
  end

  def preview_payload(preview)
    {
      action: 'preview_campaign',
      inbox_id: dig_value(preview, :inbox, :id),
      audience_size: value(preview, :audience_size),
      deliverable_count: value(preview, :deliverable_count),
      blocked_count: value(preview, :blocked_count),
      preview: preview
    }.compact
  end

  def analytics_payload(action:, analytics:)
    {
      action: action,
      campaign_id: value(analytics, :campaign_id),
      campaign_status: value(analytics, :campaign_status),
      audience_size: value(analytics, :audience_size),
      deliveries_count: value(analytics, :deliveries_count),
      success_rate: value(analytics, :success_rate),
      totals: value(analytics, :totals),
      latest_run: value(analytics, :latest_run),
      analytics: analytics
    }.compact
  end

  def latest_run_payload(latest_run)
    return if latest_run.blank?

    {
      id: latest_run.id,
      status: latest_run.status,
      total_count: latest_run.total_count,
      processed_count: latest_run.processed_count,
      successful_count: latest_run.successful_count,
      failed_count: latest_run.failed_count,
      created_at: latest_run.created_at&.iso8601
    }
  end

  def value(payload, key)
    payload[key] || payload[key.to_s]
  end

  def dig_value(payload, *keys)
    keys.reduce(payload) do |current, key|
      break if current.blank?

      value(current, key)
    end
  end
end
