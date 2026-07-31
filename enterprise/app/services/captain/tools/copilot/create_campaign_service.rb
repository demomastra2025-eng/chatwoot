# frozen_string_literal: true

require 'digest'

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
  param :idempotency_key,
        type: :string,
        desc: 'Optional stable key for retrying the same exact create request. Copilot derives one from the current operator action when omitted.',
        required: false

  def execute(title:, inbox_id:, audience_json:, idempotency_key: nil, **kwargs)
    ensure_account_administrator!

    inbox = inbox!(inbox_id)
    attrs = build_attrs(title: title, inbox: inbox, audience_json: audience_json, kwargs: kwargs)
    resolved_key = campaign_idempotency_key(attrs, supplied_key: idempotency_key)
    fingerprint = campaign_request_fingerprint(attrs) if resolved_key.present?
    campaign, idempotent_replay = save_idempotent_campaign(
      attrs.merge(idempotency_key: resolved_key, idempotency_fingerprint: fingerprint).compact
    )

    formatted_payload(
      action: 'create_campaign',
      idempotent_replay: idempotent_replay,
      campaign: campaign_payload(campaign, include_config: true),
      preview: campaign_preview(campaign)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def save_idempotent_campaign(attrs)
    key = attrs[:idempotency_key]
    existing = account.campaigns.find_by(idempotency_key: key) if key.present?
    return idempotent_replay(existing, attrs[:idempotency_fingerprint]) if existing.present?

    [save_campaign!(account.campaigns.new(attrs)), false]
  rescue ActiveRecord::RecordNotUnique
    idempotent_replay(account.campaigns.find_by!(idempotency_key: key), attrs[:idempotency_fingerprint])
  end

  def idempotent_replay(campaign, fingerprint)
    raise ArgumentError, 'idempotency_key was already used with different campaign attributes' if campaign.idempotency_fingerprint != fingerprint

    [campaign, true]
  end

  def campaign_idempotency_key(attrs, supplied_key:)
    source = supplied_key.to_s.strip.presence || copilot_action_idempotency_source(attrs)
    return if source.blank?

    Digest::SHA256.hexdigest("captain:create_campaign:v1:#{source}")
  end

  def copilot_action_idempotency_source(attrs)
    return if @copilot_thread.blank?

    latest_user_message_id = @copilot_thread.copilot_messages.user.order(id: :desc).limit(1).pick(:id)
    return if latest_user_message_id.blank?

    JSON.generate(
      thread_id: @copilot_thread.id,
      user_message_id: latest_user_message_id,
      attributes: canonical_value(campaign_idempotency_attributes(attrs))
    )
  end

  def campaign_request_fingerprint(attrs)
    Digest::SHA256.hexdigest(JSON.generate(canonical_value(campaign_idempotency_attributes(attrs))))
  end

  def campaign_idempotency_attributes(attrs)
    attrs.except(:inbox, :sender, :captain_assistant).merge(
      inbox_id: attrs[:inbox]&.id,
      sender_id: attrs[:sender]&.id,
      captain_assistant_id: attrs[:captain_assistant]&.id,
      scheduled_at: attrs[:scheduled_at]&.iso8601
    )
  end

  def canonical_value(value)
    case value
    when Hash
      value.to_h.stringify_keys.sort.to_h.transform_values { |nested| canonical_value(nested) }
    when Array
      value.map { |nested| canonical_value(nested) }
    else
      value.respond_to?(:as_json) ? value.as_json : value
    end
  end

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
