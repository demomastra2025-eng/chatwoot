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
    scheduled_at
    timezone
    body
    instructions
    attachments
    template_params
    metadata
    auto_cancel_on_incoming
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

    reminder_group.touches.map do |definition|
      normalized_definition = Reminders::DefinitionNormalizer.call(definition)
      attributes = normalized_definition.with_indifferent_access.slice(*TOUCH_ATTRIBUTE_KEYS)
      reminder = account.reminders.create!(
        attributes.merge(
          creator: actor,
          remindable: remindable,
          reminder_group: reminder_group
        )
      )
      reminder.approve! if reminder.draft? && reminder.ready_for_pending?
      reminder
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
end
