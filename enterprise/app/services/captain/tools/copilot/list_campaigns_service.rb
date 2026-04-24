class Captain::Tools::Copilot::ListCampaignsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_campaigns'
  end

  description 'List campaigns for the current account'
  param :campaign_status, type: :string, desc: 'Optional campaign status: active, completed, running, failed, or cancelled', required: false
  param :campaign_type, type: :string, desc: 'Optional campaign type: ongoing or one_off', required: false
  param :inbox_id, type: :integer, desc: 'Optional inbox ID filter', required: false
  param :limit, type: :integer, desc: 'Maximum number of campaigns to return', required: false

  def execute(campaign_status: nil, campaign_type: nil, inbox_id: nil, limit: nil)
    campaigns = filtered_campaigns(campaign_status: campaign_status, campaign_type: campaign_type, inbox_id: inbox_id)

    formatted_payload(
      filters: {
        campaign_status: valid_campaign_status?(campaign_status) ? campaign_status : nil,
        campaign_type: valid_campaign_type?(campaign_type) ? campaign_type : nil,
        inbox_id: inbox_id
      }.compact,
      total_count: campaigns.count,
      campaigns: campaigns.limit(parse_limit(limit)).map { |campaign| campaign_payload(campaign) }
    )
  end

  def active?
    account_administrator?
  end

  private

  def filtered_campaigns(campaign_status:, campaign_type:, inbox_id:)
    scope = account.campaigns.includes(:inbox, :sender, :campaign_runs).order(updated_at: :desc, id: :desc)
    scope = scope.where(campaign_status: campaign_status) if valid_campaign_status?(campaign_status)
    scope = scope.where(campaign_type: campaign_type) if valid_campaign_type?(campaign_type)
    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
    scope
  end

  def valid_campaign_status?(value)
    value.present? && ::Campaign.campaign_statuses.key?(value)
  end

  def valid_campaign_type?(value)
    value.present? && ::Campaign.campaign_types.key?(value)
  end

  def campaign_payload(campaign)
    latest_run = campaign.latest_campaign_run
    {
      id: campaign.display_id,
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
      latest_run: if latest_run.present?
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
    }
  end
end
