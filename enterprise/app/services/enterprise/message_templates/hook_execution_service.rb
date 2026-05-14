module Enterprise::MessageTemplates::HookExecutionService
  MAX_ATTACHMENT_WAIT_SECONDS = 4

  def trigger_templates
    super
    return unless should_process_captain_response?
    return unless inbox.captain_auto_reply_allowed?
    return perform_handoff unless inbox.captain_active?

    schedule_captain_response
  end

  def should_send_greeting?
    return false if captain_handling_conversation?

    super
  end

  def should_send_out_of_office_message?
    return false if captain_handling_conversation?

    super
  end

  def should_send_email_collect?
    return false if captain_handling_conversation?

    super
  end

  private

  def schedule_captain_response
    assistant = conversation.inbox.captain_assistant
    attachment_wait_time = message.attachments.blank? ? 0.seconds : calculate_attachment_wait_time

    turn_on_captain_typing_indicator(assistant)

    if assistant.message_collapse_window_seconds_value.zero?
      schedule_response_builder(assistant, attachment_wait_time)
    else
      schedule_buffered_response(assistant, attachment_wait_time)
    end
  end

  def calculate_attachment_wait_time
    attachment_count = message.attachments.size
    base_wait = 1.second

    # Wait longer for more attachments or larger files
    additional_wait = [attachment_count * 1, MAX_ATTACHMENT_WAIT_SECONDS].min.seconds
    base_wait + additional_wait
  end

  def turn_on_captain_typing_indicator(assistant)
    Captain::Conversation::TypingIndicatorService.turn_on(
      conversation: conversation,
      assistant: assistant
    )
  end

  def schedule_response_builder(assistant, attachment_wait_time)
    job_args = [conversation, assistant]
    if attachment_wait_time.zero?
      return Captain::Conversation::ResponseBuilderJob.perform_later(
        *job_args,
        expected_last_message_id: message.id
      )
    end

    Captain::Conversation::ResponseBuilderJob
      .set(wait: attachment_wait_time)
      .perform_later(*job_args, expected_last_message_id: message.id)
  end

  def schedule_buffered_response(assistant, attachment_wait_time)
    Captain::Conversation::BufferedResponseSchedulerService.new(
      conversation: conversation,
      assistant: assistant,
      message: message,
      attachment_wait_time: attachment_wait_time
    ).perform
  end

  def should_process_captain_response?
    conversation.pending? && message.incoming? && !message.voice_call? && !message.ai_voice_transcript_turn? && inbox.captain_assistant.present?
  end

  def perform_handoff
    return unless conversation.pending?

    Rails.logger.info("Captain limit exceeded, performing handoff mid-conversation for conversation: #{conversation.id}")
    conversation.messages.create!(
      message_type: :outgoing,
      account_id: conversation.account.id,
      inbox_id: conversation.inbox.id,
      content: 'Transferring to another agent for further assistance.'
    )
    conversation.bot_handoff!
    send_out_of_office_message_after_handoff
  end

  def send_out_of_office_message_after_handoff
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def captain_handling_conversation?
    conversation.pending? &&
      inbox.respond_to?(:captain_assistant) &&
      inbox.captain_assistant.present? &&
      inbox.captain_auto_reply_allowed?
  end
end
