# frozen_string_literal: true

class Captain::Tools::Copilot::CreateCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'create_campaign'
  end

  description 'Create an account outbound campaign from explicit inbox, audience JSON, message/instructions, and schedule'
  param :title, type: :string, desc: 'Campaign title', required: true
  param :inbox_id, type: :integer, desc: 'Account inbox ID', required: true
  param :audience_json, type: :string, desc: 'JSON array audience. Usually [{"type":"Label","id":123}]', required: true
  param :message, type: :string, desc: 'Static/dynamic campaign message body', required: false
  param :instructions, type: :string, desc: 'AI authoring instructions when text_mode is agent', required: false
  param :text_mode, type: :string, desc: 'static, dynamic, or agent. Defaults to static.', required: false
  param :description, type: :string, desc: 'Optional campaign description', required: false
  param :sender_id, type: :integer, desc: 'Optional account user sender ID. Defaults to current operator.', required: false
  param :captain_assistant_id, type: :integer, desc: 'Optional account Captain assistant ID for AI-authored campaigns', required: false
  param :scheduled_at, type: :string, desc: 'Optional scheduled datetime. Defaults to now for one-off inboxes.', required: false
  param :template_params_json, type: :string, desc: 'Optional JSON object for approved template params', required: false
  param :trigger_rules_json, type: :string, desc: 'Optional JSON object for website trigger campaigns', required: false
  param :trigger_only_during_business_hours, type: :boolean, desc: 'Only trigger during inbox business hours', required: false

  def execute(title:, inbox_id:, audience_json:, **kwargs)
    ensure_account_administrator!

    inbox = inbox!(inbox_id)
    attrs = build_attrs(title: title, inbox: inbox, audience_json: audience_json, kwargs: kwargs)
    campaign = save_campaign!(account.campaigns.new(attrs))

    formatted_payload(
      action: 'create_campaign',
      campaign: campaign_payload(campaign, include_config: true),
      preview: campaign_preview(campaign)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def build_attrs(title:, inbox:, audience_json:, kwargs:)
    text_mode = kwargs[:text_mode].presence || 'static'
    validate_campaign_text_mode!(text_mode)

    {
      title: title.to_s.strip,
      description: kwargs[:description],
      inbox: inbox,
      audience: parse_json_array(audience_json, field_name: 'audience_json'),
      message: kwargs[:message].to_s,
      instructions: kwargs[:instructions],
      text_mode: text_mode,
      sender: kwargs[:sender_id].present? ? user!(kwargs[:sender_id]) : @user,
      captain_assistant: captain_assistant!(kwargs[:captain_assistant_id]),
      scheduled_at: parse_campaign_datetime(kwargs[:scheduled_at], field_name: 'scheduled_at'),
      template_params: parse_json_hash(kwargs[:template_params_json], field_name: 'template_params_json', default: nil),
      trigger_rules: parse_json_hash(kwargs[:trigger_rules_json], field_name: 'trigger_rules_json', default: {}),
      trigger_only_during_business_hours: cast_boolean(kwargs[:trigger_only_during_business_hours])
    }.compact
  end
end
