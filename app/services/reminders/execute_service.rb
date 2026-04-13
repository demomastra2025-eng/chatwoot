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
    generated_payload = reminder.agent? ? generate_captain_message(conversation, mode: :touch) : {}
    message = materialize_message(
      conversation: conversation,
      sender: reminder.message_sender,
      content: generated_payload[:content].presence || reminder.renderable_body(
        conversation: conversation,
        sender: reminder.message_sender
      ),
      captain_trace: generated_payload[:captain_trace]
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

    if conversation.respond_to?(:with_captain_activity_context)
      conversation.with_captain_activity_context(reason: 'touch_ai_wakeup', reason_type: :touch) do
        conversation.pending! unless conversation.pending?
      end
    else
      conversation.pending! unless conversation.pending?
    end

    generated_payload = generate_captain_message(conversation, mode: :wakeup)
    message = materialize_message(
      conversation: conversation,
      sender: generated_payload[:assistant],
      content: generated_payload[:content],
      captain_trace: generated_payload[:captain_trace]
    )

    reminder.update!(target_conversation: conversation) if reminder.target_conversation_id != conversation.id
    reminder.complete!
    schedule_next_occurrence
    message
  end

  def generate_captain_message(conversation, mode:)
    Reminders::CaptainGeneratedMessageService.new(
      reminder: reminder,
      conversation: conversation,
      mode: mode
    ).perform
  end

  def materialize_message(conversation:, sender:, content:, captain_trace: nil)
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
end
