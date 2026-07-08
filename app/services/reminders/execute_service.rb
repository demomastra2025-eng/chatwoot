class Reminders::ExecuteService
  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return reminder if reminder.cancelled? || reminder.completed? || reminder.failed?

    case reminder.action_type
    when 'send_message'
      execute_send_message
    when 'ai_agent_wakeup'
      execute_ai_agent_wakeup
    else
      raise ArgumentError, "Unsupported touch action: #{reminder.action_type}"
    end
  rescue StandardError => e
    reminder.fail!(e.message)
    raise
  end

  private

  def execute_send_message
    conversation = Reminders::ConversationResolver.new(reminder: reminder).perform
    return reminder if cancel_due_to_campaign_conflict(conversation)
    return reminder if reschedule_outside_delivery_window(conversation)

    delivery_policy = ensure_delivery_allowed!(conversation, content_kind: reminder.content_kind, template_params: reminder.template_params,
                                                             attachments: reminder.attachments)
    generated_payload = reminder.agent? ? generate_captain_message(conversation, mode: :touch) : {}
    sender = reminder.agent? && generated_payload[:assistant].present? ? generated_payload[:assistant] : reminder.message_sender
    message = materialize_message(
      conversation: conversation,
      sender: sender,
      content: generated_payload[:content].presence || reminder.renderable_body(
        conversation: conversation,
        sender: sender
      ),
      captain_trace: generated_payload[:captain_trace],
      delivery_policy: delivery_policy
    )

    updates = {}
    updates[:target_conversation] = conversation if reminder.target_conversation_id != conversation.id
    updates[:target_contact_inbox] = conversation.contact_inbox if reminder.target_contact_inbox_id != conversation.contact_inbox_id
    reminder.update!(updates) if updates.present?
    reminder.complete!
    schedule_next_occurrence
    message
  end

  def execute_ai_agent_wakeup
    conversation = reminder.target_conversation || reminder.conversation
    raise ArgumentError, 'AI wakeup touches require a conversation target' if conversation.blank?

    return reminder if cancel_due_to_campaign_conflict(conversation)
    return reminder if reschedule_outside_delivery_window(conversation)

    delivery_policy = ensure_delivery_allowed!(conversation, content_kind: 'free_text', template_params: {}, attachments: [])

    if conversation.respond_to?(:with_captain_activity_context)
      conversation.with_captain_activity_context(reason: 'touch_ai_wakeup', reason_type: :touch) do
        transition_conversation_status!(conversation, 'pending') unless conversation.pending?
      end
    else
      transition_conversation_status!(conversation, 'pending') unless conversation.pending?
    end

    generated_payload = generate_captain_message(conversation, mode: :wakeup)
    message = materialize_message(
      conversation: conversation,
      sender: generated_payload[:assistant],
      content: generated_payload[:content],
      captain_trace: generated_payload[:captain_trace],
      delivery_policy: delivery_policy
    )

    reminder.update!(target_conversation: conversation) if reminder.target_conversation_id != conversation.id
    reminder.complete!
    schedule_next_occurrence
    message
  end

  def transition_conversation_status!(conversation, status)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: status },
      source: 'system'
    ).perform
  end

  def generate_captain_message(conversation, mode:)
    Reminders::CaptainGeneratedMessageService.new(
      reminder: reminder,
      conversation: conversation,
      mode: mode
    ).perform
  end

  def materialize_message(conversation:, sender:, content:, captain_trace: nil, delivery_policy: nil)
    message = Messages::MessageBuilder.new(
      sender,
      conversation,
      ActionController::Parameters.new(message_params(content: content))
    ).perform

    additional_attributes = (message.additional_attributes || {}).merge(
      'touch_id' => reminder.id,
      'touch_source' => 'touch'
    )
    additional_attributes['captain_trace'] = captain_trace if captain_trace.present?
    additional_attributes['delivery_policy'] = delivery_policy.as_json if delivery_policy.present?

    message.update!(additional_attributes: additional_attributes)
    message
  end

  def message_params(content:)
    {
      content: content,
      template_params: reminder.template_params.presence,
      attachments: reminder.attachments.presence,
      content_attributes: {
        touch_id: reminder.id,
        touch_source: 'touch'
      }
    }.compact
  end

  def schedule_next_occurrence
    Reminders::RecurrenceService.new(reminder: reminder).schedule_next!
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: reminder.account).capture_exception
    Rails.logger.error("[Touches] Failed to schedule next recurring touch for ##{reminder.id}: #{e.message}")
  end

  def ensure_delivery_allowed!(conversation, content_kind:, template_params:, attachments:)
    ::Outbound::DeliveryPolicy.ensure!(
      conversation: conversation,
      content_kind: content_kind,
      template_params: template_params,
      attachments: attachments,
      scheduled_at: Time.current
    )
  end

  def reschedule_outside_delivery_window(conversation)
    result = Reminders::DeliveryWindowPolicy.apply!(reminder: reminder, conversation: conversation)
    result.blocked?
  end

  def cancel_due_to_campaign_conflict(conversation)
    Reminders::CampaignConflictPolicy.new(reminder: reminder, conversation: conversation).cancel_if_conflict!
  end
end
