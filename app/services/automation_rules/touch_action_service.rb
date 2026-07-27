class AutomationRules::TouchActionService
  AUTOMATION_CANCEL_REASON = 'отменен автоматизацией'.freeze
  LEGACY_DELAY_MINUTES_FIELD = :delay_minutes
  DEFAULT_TIMING_MODE = 'absolute'.freeze
  DEFAULT_TIMEZONE = 'UTC'.freeze
  TOUCH_ATTRIBUTE_KEYS = %i[
    action_type attachments auto_cancel_on_incoming body content_kind conversation_id
    instructions manual_schedule_override metadata owner_id relative_anchor relative_offset_seconds
    post_delivery_action relative_time_mode relative_time_of_day reminder_group_id repeat_mode repeat_until_at scheduled_at
    target_contact_id target_contact_inbox_id target_conversation_id target_inbox_id template_params text_mode timing_mode timezone
  ].freeze

  attr_reader :account, :entity_kind, :record, :rule

  def initialize(rule:, account:, record:, entity_kind:)
    @rule = rule
    @account = account
    @record = record
    @entity_kind = entity_kind
  end

  def apply_touch_plan(action_params)
    reminder_group = load_touch_plan!(action_params)

    result = Reminders::PlanApplicationService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: record,
      actor: rule,
      source: 'automation'
    ).perform
    reminders = result.touches

    reminders.each do |reminder|
      Reminders::CampaignConflictPolicy.new(reminder: reminder).cancel_if_conflict!
    end

    reminders
  end

  def create_touch(action_params)
    params = normalize_touch_params(action_params)

    reminder = Reminder.transaction do
      created_reminder = Reminders::CreateService.new(
        account: account,
        remindable: record,
        attributes: build_touch_attributes(params)
      ).perform
      created_reminder.mark_automation_provenance!(rule)
      created_reminder
    end

    Reminders::CampaignConflictPolicy.new(reminder: reminder).cancel_if_conflict!
    reminder
  end

  def cancel_touches(action_params)
    params = normalize_cancel_params(action_params)
    reminder_group = load_optional_touch_plan!(params[:reminder_group_id])

    Reminders::BulkCancelService.new(
      account: account,
      remindable: record,
      reminder_group: reminder_group,
      touch_source: reminder_group.present? ? nil : 'automation',
      actor: nil,
      reason: params[:reason].presence || AUTOMATION_CANCEL_REASON,
      metadata: {
        'automation_rule_id' => rule.id,
        'touch_source' => 'automation',
        'cancelled_via' => 'automation_cancel_touches',
        'cancel_touches_entity_kind' => entity_kind
      }
    ).perform
  end

  private

  def delay_minutes(params)
    Integer(params[LEGACY_DELAY_MINUTES_FIELD] || 0)
  rescue ArgumentError, TypeError
    raise ArgumentError, 'create_touch delay_minutes must be a non-negative integer'
  end

  def build_touch_attributes(params)
    attributes = params.slice(*TOUCH_ATTRIBUTE_KEYS).to_h.symbolize_keys
    attributes[:action_type] = attributes[:action_type].presence || 'send_message'
    attributes[:content_kind] = attributes[:content_kind].presence || 'free_text'
    attributes[:timing_mode] = attributes[:timing_mode].presence || DEFAULT_TIMING_MODE
    attributes[:timezone] = attributes[:timezone].presence || DEFAULT_TIMEZONE
    attributes[:metadata] = normalized_touch_metadata(attributes[:metadata])
    attributes[:auto_cancel_on_incoming] = auto_cancel_on_incoming_value(params)

    apply_legacy_delay_defaults!(attributes, params)
    attributes
  end

  def apply_legacy_delay_defaults!(attributes, params)
    return if explicit_timing?(attributes)

    attributes[:timing_mode] = DEFAULT_TIMING_MODE
    attributes[:scheduled_at] = Time.current + delay_minutes(params).minutes
  end

  def explicit_timing?(attributes)
    attributes[:scheduled_at].present? ||
      attributes[:relative_anchor].present? ||
      attributes[:relative_offset_seconds].present? ||
      attributes[:timing_mode].to_s == 'relative'
  end

  def normalized_touch_metadata(metadata)
    (metadata || {}).to_h.stringify_keys.merge(automation_metadata)
  end

  def auto_cancel_on_incoming_value(params)
    Reminders::BooleanParam.call(
      params[:auto_cancel_on_incoming],
      default: false,
      field_name: 'auto_cancel_on_incoming'
    )
  end

  def touch_content_present?(params)
    action_type = params[:action_type].presence || 'send_message'
    return true if action_type.to_s == 'ai_agent_wakeup'

    content_kind = params[:content_kind].presence || 'free_text'
    text_mode = Reminders::TextModeResolver.call(
      action_type: action_type,
      body: params[:body],
      instructions: params[:instructions],
      text_mode: params[:text_mode]
    )

    return params[:instructions].to_s.strip.present? if text_mode.to_s == 'agent'
    return params[:template_params].respond_to?(:to_h) && params[:template_params].to_h.present? if content_kind.to_s == 'channel_template'

    params[:body].to_s.strip.present? || Array(params[:attachments]).any?
  end

  def touch_timing_supported?(params)
    return false if params.key?(LEGACY_DELAY_MINUTES_FIELD) && delay_minutes(params).negative?
    return false if params[:timing_mode].to_s == 'relative' && params[:relative_anchor].blank?
    return false if params[:timing_mode].to_s == 'relative' && params[:relative_offset_seconds].blank?
    if fixed_time_of_day_timing?(params) &&
       params[:relative_time_of_day].to_s !~ Reminder::RELATIVE_TIME_OF_DAY_FORMAT
      return false
    end

    true
  rescue ArgumentError
    false
  end

  def fixed_time_of_day_timing?(params)
    params[:timing_mode].to_s == 'relative' &&
      params[:relative_time_mode].to_s == Reminder::RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY
  end

  def automation_metadata
    {
      'automation_rule_id' => rule.id,
      'touch_source' => 'automation'
    }
  end

  def load_touch_plan!(action_params)
    reminder_group = account.reminder_groups.kept.find_by(id: normalize_action_param(action_params))
    raise ArgumentError, 'apply_touch_plan requires a valid touch plan' if reminder_group.blank?
    raise ArgumentError, 'Touch plan does not support this entity type' unless reminder_group.entity_kind_supported?(entity_kind)

    reminder_group
  end

  def load_optional_touch_plan!(reminder_group_id)
    return if reminder_group_id.blank?

    reminder_group = account.reminder_groups.kept.find_by(id: reminder_group_id)
    raise ArgumentError, 'cancel_touches requires a valid touch plan' if reminder_group.blank?
    raise ArgumentError, 'Touch plan does not support this entity type' unless reminder_group.entity_kind_supported?(entity_kind)

    reminder_group
  end

  def normalize_action_param(action_params)
    raw = first_action_param(action_params)
    raw = raw.with_indifferent_access if raw.is_a?(Hash)
    value = raw.is_a?(Hash) ? (raw[:reminder_group_id] || raw[:touch_plan_id] || raw[:id]) : raw
    value.to_s.presence
  end

  def normalize_optional_action_param(value)
    value = value.to_s.strip
    return if value.blank? || value == 'nil'

    value
  end

  def normalize_cancel_params(action_params)
    raw = first_action_param(action_params)

    return { reminder_group_id: normalize_optional_action_param(raw) } unless raw.is_a?(Hash)

    params = raw.with_indifferent_access
    {
      reminder_group_id: normalize_optional_action_param(params[:reminder_group_id] || params[:touch_plan_id]),
      reason: params[:reason]
    }
  end

  def normalize_touch_params(action_params)
    raw = first_action_param(action_params)
    raise ArgumentError, 'create_touch requires a touch definition' unless raw.is_a?(Hash)

    params = raw.with_indifferent_access
    raise ArgumentError, 'create_touch content is required' unless touch_content_present?(params)
    raise ArgumentError, 'create_touch timing is invalid' unless touch_timing_supported?(params)

    validate_post_delivery_action!(params)

    params
  end

  def validate_post_delivery_action!(params)
    action = params[:post_delivery_action].to_s.presence
    return if action.blank?

    raise ArgumentError, 'create_touch post_delivery_action is invalid' unless valid_post_delivery_action?(params, action)
    return if params[:repeat_mode].blank? || params[:repeat_mode].to_s == 'once'

    raise ArgumentError, 'create_touch post_delivery_action requires a one-time touch'
  end

  def valid_post_delivery_action?(params, action)
    entity_kind == 'conversation' &&
      action.in?(Reminder::POST_DELIVERY_ACTIONS) &&
      (params[:action_type].presence || 'send_message').to_s == 'send_message'
  end

  def first_action_param(action_params)
    raw = action_params
    raw = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
    raw = raw.to_h if raw.respond_to?(:to_h) && !raw.is_a?(Hash) && !raw.is_a?(Array)
    return raw if raw.is_a?(Hash)
    return raw.first if raw.is_a?(Array)

    raw
  end
end
