class Reminders::ApplyGroupService
  TOUCH_ATTRIBUTE_KEYS = %w[
    action_type
    content_kind
    text_mode
    timing_mode
    repeat_mode
    repeat_until_at
    relative_anchor
    relative_offset_seconds
    relative_time_mode
    relative_time_of_day
    manual_schedule_override
    scheduled_at
    timezone
    body
    instructions
    attachments
    template_params
    metadata
    auto_cancel_on_incoming
    post_delivery_action
    target_inbox_id
    target_contact_id
    target_contact_inbox_id
    target_conversation_id
  ].freeze

  attr_reader :account, :actor, :remindable, :reminder_group

  def initialize(account:, reminder_group:, remindable:, actor:)
    @account = account
    @reminder_group = reminder_group
    @remindable = remindable
    @actor = actor
  end

  def perform
    raise ArgumentError, 'Touch plan does not support this entity kind' unless reminder_group.entity_kind_supported?(entity_kind)

    definitions = reminder_group.touches.map { |definition| Reminders::DefinitionNormalizer.call(definition) }
    definitions.each { |definition| validate_post_delivery_action!(definition) }

    account.reminders.transaction do
      definitions.map { |definition| create_reminder!(definition) }
    end
  end

  private

  def entity_kind
    case remindable
    when Conversation
      'conversation'
    when Crm::Deal
      'deal'
    when Crm::Task
      'task'
    when Scheduling::Appointment
      'appointment'
    else
      raise ArgumentError, "Unsupported remindable: #{remindable.class.name}"
    end
  end

  def create_reminder!(definition)
    reminder = account.reminders.create!(
      touch_attributes_from(definition).merge(
        creator: reminder_creator,
        remindable: remindable,
        reminder_group: reminder_group
      )
    )
    reminder.mark_automation_provenance!(actor) if actor.is_a?(AutomationRule)
    reminder.approve! if reminder.draft? && reminder.ready_for_pending?
    reminder
  end

  def touch_attributes_from(definition)
    attributes = definition.with_indifferent_access.slice(*TOUCH_ATTRIBUTE_KEYS)
    attributes[:action_type] = attributes[:action_type].presence || 'send_message'
    attributes[:repeat_mode] = attributes[:repeat_mode].presence || 'once'
    explicit_auto_cancel = attributes.key?(:auto_cancel_on_incoming)
    attributes[:auto_cancel_on_incoming] = Reminders::BooleanParam.call(
      attributes[:auto_cancel_on_incoming],
      default: false,
      field_name: 'auto_cancel_on_incoming'
    )
    return attributes unless explicit_auto_cancel

    attributes[:metadata] = attributes[:metadata].to_h.stringify_keys.merge(
      'auto_cancel_on_incoming_explicit' => attributes[:auto_cancel_on_incoming]
    )
    attributes
  end

  def validate_post_delivery_action!(definition)
    params = definition.with_indifferent_access
    action = params[:post_delivery_action].to_s.presence
    return if action.blank?

    return if supported_post_delivery_action?(params, action)

    raise ArgumentError, 'Touch plan post_delivery_action is invalid'
  end

  def supported_post_delivery_action?(params, action)
    entity_kind == 'conversation' &&
      action.in?(Reminder::POST_DELIVERY_ACTIONS) &&
      (params[:action_type].presence || 'send_message').to_s == 'send_message' &&
      (params[:repeat_mode].presence || 'once').to_s == 'once'
  end

  def reminder_creator
    actor if actor.is_a?(User)
  end
end
