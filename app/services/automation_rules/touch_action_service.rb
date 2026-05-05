class AutomationRules::TouchActionService
  AUTOMATION_CANCEL_REASON = 'отменен автоматизацией'.freeze

  attr_reader :account, :entity_kind, :record, :rule

  def initialize(rule:, account:, record:, entity_kind:)
    @rule = rule
    @account = account
    @record = record
    @entity_kind = entity_kind
  end

  def apply_touch_plan(action_params)
    reminder_group = load_touch_plan!(action_params)

    reminders = Reminders::ApplyGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: record,
      actor: nil
    ).perform

    reminders.each do |reminder|
      mark_automation_reminder!(reminder)
      Reminders::CampaignConflictPolicy.new(reminder: reminder).cancel_if_conflict!
    end

    reminders
  end

  def create_touch(action_params)
    params = normalize_touch_params(action_params)

    reminder = Reminders::CreateService.new(
      account: account,
      remindable: record,
      attributes: {
        action_type: 'send_message',
        content_kind: 'free_text',
        text_mode: Reminders::TextModeResolver.call(
          action_type: 'send_message',
          body: params[:body],
          instructions: nil
        ),
        timing_mode: 'absolute',
        scheduled_at: Time.current + delay_minutes(params).minutes,
        timezone: 'UTC',
        body: params[:body],
        auto_cancel_on_incoming: Reminders::BooleanParam.call(
          params[:auto_cancel_on_incoming],
          default: false,
          field_name: 'auto_cancel_on_incoming'
        ),
        metadata: automation_metadata
      }
    ).perform

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
    Integer(params[:delay_minutes] || 0)
  rescue ArgumentError, TypeError
    raise ArgumentError, 'create_touch delay_minutes must be a non-negative integer'
  end

  def automation_metadata
    {
      'automation_rule_id' => rule.id,
      'touch_source' => 'automation'
    }
  end

  def mark_automation_reminder!(reminder)
    metadata = reminder.metadata.to_h.merge(automation_metadata)
    reminder.update!(metadata: metadata) if reminder.metadata != metadata
    reminder
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
    Array(action_params).first.to_s.presence
  end

  def normalize_optional_action_param(value)
    value = value.to_s.strip
    return if value.blank? || value == 'nil'

    value
  end

  def normalize_cancel_params(action_params)
    raw = Array(action_params).first
    raw = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
    raw = raw.to_h if raw.respond_to?(:to_h) && !raw.is_a?(Hash)

    return { reminder_group_id: normalize_optional_action_param(raw) } unless raw.is_a?(Hash)

    params = raw.with_indifferent_access
    {
      reminder_group_id: normalize_optional_action_param(params[:reminder_group_id] || params[:touch_plan_id]),
      reason: params[:reason]
    }
  end

  def normalize_touch_params(action_params)
    raw = Array(action_params).first
    raw = raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
    raw = raw.to_h if raw.respond_to?(:to_h) && !raw.is_a?(Hash)
    raise ArgumentError, 'create_touch requires a touch definition' unless raw.is_a?(Hash)

    params = raw.with_indifferent_access
    raise ArgumentError, 'create_touch body is required' if params[:body].to_s.strip.blank?
    raise ArgumentError, 'create_touch delay_minutes must be a non-negative integer' if delay_minutes(params).negative?

    params
  end
end
