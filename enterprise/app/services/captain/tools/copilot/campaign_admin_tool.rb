# frozen_string_literal: true

class Captain::Tools::Copilot::CampaignAdminTool < Captain::Tools::Copilot::BaseAccountTool
  def active?
    account_administrator?
  end

  private

  def find_campaign!(campaign_id)
    account.campaigns
           .includes(:inbox, :sender, :captain_assistant, :campaign_runs)
           .find_by(display_id: campaign_id) || account.campaigns.find(campaign_id)
  end

  def inbox!(inbox_id)
    account.inboxes.active.find(inbox_id)
  end

  def user!(user_id)
    account.users.find(user_id)
  end

  def contact!(contact_id)
    account.contacts.find(contact_id)
  end

  def captain_assistant!(captain_assistant_id)
    return nil if captain_assistant_id.blank?

    account.captain_assistants.find(captain_assistant_id)
  end

  def parse_json_array(value, field_name:, default: [])
    return default if value.nil?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON array" unless parsed.is_a?(Array)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def parse_json_hash(value, field_name:, default: {})
    return default if value.nil?
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def parse_campaign_datetime(value, field_name:)
    return nil if value.blank?

    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a valid datetime" if parsed.blank?

    parsed
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{field_name} must be a valid datetime"
  end

  def validate_campaign_text_mode!(value)
    return if value.blank? || Campaign.text_modes.key?(value.to_s)

    raise ArgumentError, "text_mode must be one of: #{Campaign.text_modes.keys.join(', ')}"
  end

  def validate_campaign_status!(value)
    return if value.blank? || Campaign.campaign_statuses.key?(value.to_s)

    raise ArgumentError, "campaign_status must be one of: #{Campaign.campaign_statuses.keys.join(', ')}"
  end

  def campaign_payload(campaign, include_config: true)
    latest_run = campaign.latest_campaign_run
    payload = {
      id: campaign.display_id,
      record_id: campaign.id,
      title: campaign.title,
      description: campaign.description,
      inbox_id: campaign.inbox_id,
      inbox_name: campaign.inbox&.name,
      inbox_type: campaign.inbox&.inbox_type,
      sender_id: campaign.sender_id,
      sender_name: campaign.sender&.name,
      captain_assistant_id: campaign.captain_assistant_id,
      captain_assistant_name: campaign.captain_assistant&.name,
      campaign_status: campaign.campaign_status,
      campaign_type: campaign.campaign_type,
      enabled: campaign.enabled,
      text_mode: campaign.text_mode,
      scheduled_at: campaign.scheduled_at&.iso8601,
      trigger_only_during_business_hours: campaign.trigger_only_during_business_hours,
      created_at: campaign.created_at&.iso8601,
      updated_at: campaign.updated_at&.iso8601,
      latest_run: latest_run_payload(latest_run)
    }.compact

    payload.merge!(campaign_config_payload(campaign)) if include_config
    payload
  end

  def campaign_config_payload(campaign)
    {
      message: campaign.message,
      instructions: campaign.instructions,
      audience: campaign.audience,
      trigger_rules: campaign.trigger_rules,
      template_params: campaign.template_params
    }
  end

  def latest_run_payload(run)
    return if run.blank?

    {
      id: run.id,
      status: run.status,
      total_count: run.total_count,
      processed_count: run.processed_count,
      successful_count: run.successful_count,
      failed_count: run.failed_count,
      skipped_count: run.skipped_count,
      progress_percentage: run.progress_percentage,
      error_message: run.error_message,
      created_at: run.created_at&.iso8601,
      started_at: run.started_at&.iso8601,
      completed_at: run.completed_at&.iso8601
    }.compact
  end

  def campaign_preview(campaign)
    Campaigns::PreviewService.new(
      account: account,
      inbox: campaign.inbox,
      audience: campaign.audience,
      message: campaign.message,
      instructions: campaign.instructions,
      text_mode: campaign.text_mode,
      template_params: campaign.template_params,
      scheduled_at: campaign.scheduled_at
    ).call
  end

  def ensure_launchable!(campaign, preview)
    audience_size = preview[:audience_size] || preview['audience_size']
    deliverable_count = preview[:deliverable_count] || preview['deliverable_count']

    raise ArgumentError, 'Only one-off campaigns can be launched' unless campaign.one_off?
    raise ArgumentError, 'Campaign must be active before launch' unless campaign.active?
    raise ArgumentError, 'Campaign audience is empty' if audience_size.to_i.zero?
    raise ArgumentError, 'Campaign has no deliverable recipients' if deliverable_count.to_i.zero?

    Campaigns::TemplateParamsValidator.validate!(inbox: campaign.inbox, template_params: campaign.template_params)
  end

  def save_campaign!(campaign)
    campaign.save!
    campaign
  rescue ActiveRecord::RecordInvalid
    raise ArgumentError, campaign.errors.full_messages.join(', ')
  end
end
