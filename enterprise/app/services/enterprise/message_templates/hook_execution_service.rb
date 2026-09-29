module Enterprise::MessageTemplates::HookExecutionService
  MAX_ATTACHMENT_WAIT_SECONDS = 4

  def trigger_templates
    super
    return unless should_process_captain_response?

    auto_reply_allowed = inbox.captain_auto_reply_allowed?
    return schedule_captain_response if auto_reply_allowed && inbox.captain_active?

    open_conversation_for_human_response(quota_used_up: auto_reply_allowed)
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

    Captain::Conversation::TypingIndicatorService.turn_on(conversation: conversation, assistant: assistant)

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

  def schedule_response_builder(assistant, attachment_wait_time)
    job_args = [conversation, assistant]
    conversation.stamp_captain_control_generation!(message)
    if attachment_wait_time.zero?
      return Captain::Conversation::ResponseBuilderJob.perform_later(
        *job_args,
        expected_last_message_id: message.id
      )
    end

    Captain::Conversation::ResponseBuilderJob
      .set(wait: attachment_wait_time)
      .perform_later(
        *job_args,
        expected_last_message_id: message.id
      )
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
    conversation_accepts_captain_response? && message.incoming? && !message.voice_call? &&
      !message.ai_voice_transcript_turn? && inbox.captain_assistant.present?
  end

  def conversation_accepts_captain_response?
    conversation.pending?
  end

  # Captain handles a pending conversation only while it may answer now. When it
  # is outside its schedule or out of quota, the inbox greeting, out-of-office and
  # email-collect templates apply as in an inbox without Captain.
  def captain_handling_conversation?
    conversation_accepts_captain_response? &&
      inbox.respond_to?(:captain_assistant) &&
      inbox.captain_assistant.present? &&
      inbox.captain_auto_reply_allowed? &&
      inbox.captain_active?
  end

  # System safety net: Captain answers only pending conversations, so a pending
  # conversation that Captain may not answer now must not wait unseen. It opens
  # for people through the standard status transition (system source, no actor),
  # which runs assignment and notifications. This is not a Captain handoff
  # decision; the customer only gets the inbox templates sent above, plus the
  # assistant's own handoff message when quota ran out.
  def open_conversation_for_human_response(quota_used_up:)
    previous_current = [Current.user, Current.executed_by]
    Current.user = Current.executed_by = nil
    quota_used_up ? handoff_without_captain_quota : open_outside_captain_schedule
    return if conversation.pending?

    Captain::Conversation::TypingIndicatorService.turn_off(conversation: conversation, assistant: inbox.captain_assistant)
  ensure
    Current.user, Current.executed_by = previous_current if previous_current
  end

  def open_outside_captain_schedule
    Rails.logger.info("[CAPTAIN][AutoReply] Opening conversation #{conversation.id} because Captain auto-reply is not allowed now")
    Conversation.transaction do
      next unless Conversation.lock.find(conversation.id).pending?

      Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
    end
  end

  # Captain may answer now but the account has no Captain quota left. The fenced
  # system handoff opens the conversation once; a human reply or status change
  # that came first wins.
  def handoff_without_captain_quota
    Rails.logger.info("[CAPTAIN][AutoReply] Handing conversation #{conversation.id} to people because Captain quota is used up")
    conversation.bot_handoff!(actor: nil, source: 'system', fence: { last_message_id: message.id }) do
      Captain::SystemHandoffMessageService.new(conversation: conversation, assistant: inbox.captain_assistant).perform
    end
  end
end
