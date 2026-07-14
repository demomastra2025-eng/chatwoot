class Reminders::PostDeliveryActionService
  def initialize(message:)
    @message = message
  end

  def perform
    return false unless provider_acknowledged?

    reminder = reminder_for_message
    return false if reminder.blank?

    reminder.with_lock do
      message.with_lock do
        next false unless provider_acknowledged?
        next false unless normalized_touch_id == reminder.id

        conversation = reminder.post_delivery_conversation
        audit_context = audit_context(reminder)
        next false unless eligible?(reminder, conversation, audit_context)

        execute_action!(reminder, conversation, audit_context)
        reminder.mark_post_delivery_action_executed!(message.id)
        true
      end
    end
  end

  private

  attr_reader :message

  def provider_acknowledged?
    message.outgoing? && message.source_id.present? && !message.failed?
  end

  def reminder_for_message
    touch_id = normalized_touch_id
    return if touch_id.blank?

    message.account.reminders.find_by(id: touch_id)
  end

  def normalized_touch_id
    raw_ids = [
      message.additional_attributes.to_h['touch_id'],
      message.content_attributes.to_h['touch_id']
    ].compact
    return if raw_ids.blank?
    return unless raw_ids.all? { |value| value.to_s.match?(/\A[1-9]\d*\z/) }

    normalized_ids = raw_ids.map(&:to_i).uniq
    normalized_ids.one? ? normalized_ids.first : nil
  end

  def eligible?(reminder, conversation, audit_context)
    reminder.post_delivery_action.present? &&
      reminder.send_message? &&
      reminder.once? &&
      audit_context.present? &&
      canonical_conversation?(conversation) &&
      pending_action?(reminder)
  end

  def canonical_conversation?(conversation)
    conversation.present? &&
      conversation.id == message.conversation_id &&
      conversation.account_id == message.account_id &&
      conversation.inbox_id == message.inbox_id
  end

  def pending_action?(reminder)
    reminder.delivery_materialized_for?(message.id) &&
      !reminder.post_delivery_action_executed_for?(message.id)
  end

  def execute_action!(reminder, conversation, audit_context)
    case reminder.post_delivery_action
    when Reminder::POST_DELIVERY_ACTION_RESOLVE_CONVERSATION
      resolve_conversation!(conversation, audit_context)
    else
      raise ArgumentError, "Unsupported post-delivery action: #{reminder.post_delivery_action}"
    end
  end

  def resolve_conversation!(conversation, audit_context)
    conversation.with_lock do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'resolved' },
        actor: audit_context.fetch(:actor),
        source: audit_context.fetch(:source)
      ).perform
    end
  end

  def audit_context(reminder)
    api_actor = message.account.users.find_by(id: reminder.creator_id)
    return { actor: api_actor, source: 'api' } if api_actor.present?

    automation_actor = automation_rule(reminder)
    return if automation_actor.blank?

    { actor: automation_actor, source: 'automation' }
  end

  def automation_rule(reminder)
    metadata = reminder.metadata.to_h
    return unless metadata[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'

    rule_id = metadata[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    return if rule_id.blank?

    message.account.automation_rules.find_by(id: rule_id)
  end
end
