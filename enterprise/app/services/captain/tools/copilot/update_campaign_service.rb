# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'update_campaign'
  end

  description 'Update an editable account campaign configuration before launch/completion'
  param :campaign_id, type: :integer, desc: 'Campaign display ID from list_campaigns', required: true
  param :title, type: :string, desc: 'New campaign title', required: false
  param :description, type: :string, desc: 'New description', required: false
  param :message, type: :string, desc: 'New message body', required: false
  param :instructions, type: :string, desc: 'New AI instructions', required: false
  param :text_mode, type: :string, desc: 'static, dynamic, or agent', required: false
  param :audience_json, type: :string, desc: 'New JSON array audience', required: false
  param :scheduled_at, type: :string, desc: 'New scheduled datetime', required: false
  param :template_params_json, type: :string, desc: 'New JSON object template params', required: false
  param :trigger_rules_json, type: :string, desc: 'New JSON object trigger rules', required: false
  param :enabled, type: :boolean, desc: 'Enable or disable trigger-style campaigns', required: false
  param :trigger_only_during_business_hours, type: :boolean, desc: 'Only trigger during inbox business hours', required: false

  def execute(campaign_id:, **kwargs)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    attrs = build_attrs(kwargs)
    raise ArgumentError, 'At least one field is required' if attrs.blank?

    campaign.assign_attributes(attrs)
    save_campaign!(campaign)

    formatted_payload(
      action: 'update_campaign',
      campaign: campaign_payload(campaign, include_config: true),
      preview: campaign_preview(campaign)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def build_attrs(kwargs)
    attrs = {}
    attrs[:title] = kwargs[:title].to_s.strip if kwargs[:title].present?
    attrs[:description] = kwargs[:description] if kwargs.key?(:description)
    attrs[:message] = kwargs[:message].to_s if kwargs.key?(:message)
    attrs[:instructions] = kwargs[:instructions] if kwargs.key?(:instructions)
    if kwargs.key?(:audience_json) && !kwargs[:audience_json].nil?
      attrs[:audience] =
        parse_json_array(kwargs[:audience_json], field_name: 'audience_json')
    end
    attrs[:scheduled_at] = parse_campaign_datetime(kwargs[:scheduled_at], field_name: 'scheduled_at') if kwargs.key?(:scheduled_at)
    if kwargs.key?(:template_params_json)
      attrs[:template_params] =
        parse_json_hash(kwargs[:template_params_json], field_name: 'template_params_json', default: nil)
    end
    if kwargs.key?(:trigger_rules_json)
      attrs[:trigger_rules] =
        parse_json_hash(kwargs[:trigger_rules_json], field_name: 'trigger_rules_json', default: {})
    end
    if kwargs[:text_mode].present?
      validate_campaign_text_mode!(kwargs[:text_mode])
      attrs[:text_mode] = kwargs[:text_mode].to_s
    end
    attrs[:enabled] = cast_boolean(kwargs[:enabled]) if kwargs.key?(:enabled)
    if kwargs.key?(:trigger_only_during_business_hours)
      attrs[:trigger_only_during_business_hours] = cast_boolean(kwargs[:trigger_only_during_business_hours])
    end
    attrs
  end
end
