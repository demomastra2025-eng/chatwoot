class AutomationRules::TouchActionService
  AUTOMATION_CANCEL_REASON = 'отменен автоматизацией'.freeze
  LEGACY_DELAY_MINUTES_FIELD = :delay_minutes
  DEFAULT_TIMING_MODE = 'absolute'.freeze
  DEFAULT_TIMEZONE = 'UTC'.freeze
  TOUCH_ATTRIBUTE_KEYS = %i[
    action_type attachments auto_cancel_on_incoming body content_kind conversation_id
    instructions manual_schedule_override metadata owner_id relative_anchor relative_offset_seconds
    post_delivery_action relative_time_mode relative_time_of_day reminder_group_id repeat_mode repeat_until_at scheduled_at
    response_action response_button_index
    target_contact_id target_contact_inbox_id target_conversation_id target_inbox_id template_params text_mode timing_mode timezone
  ].freeze

  attr_reader :account, :entity_kind, :record, :rule, :trigger_message

  def initialize(rule:, account:, record:, entity_kind:, trigger_message: nil)
    @rule = rule
    @account = account
    @record = record
    @entity_kind = entity_kind
    @trigger_message = trigger_message
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

  def create_touch(action_params = nil, action_id: nil, action_key: nil, **keyword_params)
    action_params = keyword_params if action_params.nil? && keyword_params.present?
    params = normalize_touch_params(action_params)
    return create_deferred_touch(params, action_id) if deferred_action?(params, action_id)

    action_key = action_key.presence || action_id.presence || 'create_touch'
    action_signature = automation_action_signature(params) if trigger_message.blank?
    reminder = find_or_create_event_touch(params, action_key, action_signature)

    Reminders::StaleAutomationTouchService.new(reminder: reminder, trigger_message: trigger_message).perform
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

  def find_or_create_event_touch(params, action_key, action_signature)
    Reminder.transaction do
      lock_automation_event!(action_key, action_signature)
      existing_event_touch(action_key, action_signature) || create_automation_touch(params, action_key, action_signature)
    end
  rescue ActiveRecord::RecordInvalid => e
    raise unless duplicate_open_touch_error?(e.record)

    account.reminders.where(status: Reminder::OPEN_STATUSES, fingerprint: e.record.fingerprint).first || raise
  end

  def duplicate_open_touch_error?(reminder)
    reminder.is_a?(Reminder) &&
      reminder.errors.to_hash == { base: ['An open touch with the same content already exists'] }
  end

  def create_automation_touch(params, action_key, action_signature)
    reminder = Reminders::CreateService.new(
      account: account,
      remindable: record,
      attributes: build_touch_attributes(params)
    ).perform
    reminder.mark_automation_provenance!(
      rule,
      trigger_message: trigger_message,
      action_key: action_key,
      action_signature: action_signature
    )
    reminder
  end

  def existing_event_touch(action_key, action_signature)
    metadata = {
      Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id,
      Reminder::AUTOMATION_ACTION_KEY => action_key
    }
    metadata[Reminder::AUTOMATION_TRIGGER_MESSAGE_ID_KEY] = trigger_message.id if trigger_message.present?
    scope = account.reminders.where(remindable: record).where('metadata @> ?', metadata.to_json)
    scope = scope.where(status: Reminder::OPEN_STATUSES) if trigger_message.blank?
    return scope.first if action_signature.blank?

    matching_touch = scope.where('metadata @> ?', { Reminder::AUTOMATION_ACTION_SIGNATURE_KEY => action_signature }.to_json).first
    return matching_touch if matching_touch.present?

    legacy_touch = scope.where("COALESCE(metadata ->> '#{Reminder::AUTOMATION_ACTION_SIGNATURE_KEY}', '') = ''").first
    adopt_legacy_event_touch(legacy_touch, action_key, action_signature)
  end

  def adopt_legacy_event_touch(legacy_touch, action_key, action_signature)
    return if legacy_touch.blank?

    rule.with_lock do
      rule.reload
      return if rule.updated_at > legacy_touch.created_at

      legacy_touch.with_lock do
        legacy_touch.reload
        return if legacy_touch.metadata[Reminder::AUTOMATION_ACTION_SIGNATURE_KEY].present?

        legacy_touch.mark_automation_provenance!(
          rule,
          trigger_message: nil,
          action_key: action_key,
          action_signature: action_signature
        )
      end
    end
    legacy_touch
  end

  def lock_automation_event!(action_key, action_signature)
    source_parts = [account.id, rule.id, entity_kind, record.id, trigger_message&.id, action_key]
    source_parts << action_signature if action_signature.present?
    source = source_parts.join(':')
    lock_key = Digest::SHA256.hexdigest("automation-touch-event:#{source}").first(16).to_i(16) % ((2**63) - 1)
    Reminder.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
  end

  def automation_action_signature(params)
    Digest::SHA256.hexdigest(JSON.generate(canonical_json_value(params)))
  end

  def canonical_json_value(value)
    return value.deep_stringify_keys.sort.to_h.transform_values { |nested| canonical_json_value(nested) } if value.is_a?(Hash)
    return value.map { |nested| canonical_json_value(nested) } if value.is_a?(Array)

    value
  end

  def deferred_action?(params, action_id)
    action_id.present? && Reminders::DeferredAutomationActionPolicy.new(
      account: account,
      remindable: record,
      definition: params
    ).eligible?
  end

  def create_deferred_touch(params, action_id)
    Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: rule,
      action_id: action_id,
      remindable: record,
      definition: params
    ).perform
  end

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
    validate_response_action!(params)

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

  def validate_response_action!(params)
    action = params[:response_action].to_s.presence
    button_index = params[:response_button_index]
    return if action.blank? && button_index.blank?

    return if valid_response_action?(params, action, button_index)

    raise ArgumentError, 'create_touch response_action is invalid'
  end

  def valid_response_action?(params, action, button_index)
    entity_kind == 'appointment' &&
      action == Reminder::RESPONSE_ACTION_CONFIRM_APPOINTMENT &&
      button_index.to_s == '0' &&
      (params[:action_type].presence || 'send_message').to_s == 'send_message' &&
      params[:content_kind].to_s == 'channel_template' &&
      (params[:repeat_mode].presence || 'once').to_s == 'once' &&
      valid_confirmation_template_button?(params, button_index.to_i)
  end

  def valid_confirmation_template_button?(params, button_index)
    inbox = account.inboxes.find_by(id: params[:target_inbox_id].presence || record.try(:conversation)&.inbox_id)

    Reminders::ConfirmationTemplateValidator.new(
      account: account,
      inbox: inbox,
      template_params: params[:template_params],
      button_index: button_index
    ).valid?
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
