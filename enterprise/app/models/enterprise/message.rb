module Enterprise::Message
  include Enterprise::Message::OrphanPendingHandoff

  private

  # Most public replies never involve Captain; they must not lock the
  # conversation. Plain SQL keeps the conversation's thread association
  # unloaded for the create callbacks that run after this one.
  def captain_inbox_involved?
    thread_ids = ::CommunicationThreadConversation.where(conversation_id: conversation.id).select(:communication_thread_id)
    thread_conversation_ids = ::CommunicationThreadConversation.where(communication_thread_id: thread_ids).select(:conversation_id)
    thread_inbox_ids = ::Conversation.where(account_id: conversation.account_id, id: thread_conversation_ids).select(:inbox_id)

    ::CaptainInbox.where(inbox_id: conversation.inbox_id).or(::CaptainInbox.where(inbox_id: thread_inbox_ids)).exists?
  end

  def mark_pending_conversation_as_open_for_human_response(runtime_events: true)
    orphan_handoff_triggered = false
    orphan_handoff_triggered = orphan_pending_handoff_trigger?
    if orphan_handoff_triggered
      return if activate_orphan_pending_human_control_after_commit
    end
    return unless runtime_events
    return unless captain_auto_open_candidate?

    without_current_actor do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'open' },
        source: 'system'
      ).perform
      return unless conversation.saved_change_to_status?

      create_captain_auto_open_activity_message
    end
  ensure
    publish_captain_takeover_cancellations if runtime_events || orphan_handoff_triggered
  end

  def captain_takeover_cancellation_services
    thread = conversation.communication_thread
    conversations = thread ? thread.conversations.where(account_id: conversation.account_id).pending : [conversation].select(&:pending?)
    conversations.filter_map do |candidate|
      # Look the assistant up by inbox: the caller's cached inbox may predate its Captain link.
      assistant = ::CaptainInbox.find_by(inbox_id: candidate.inbox_id)&.captain_assistant
      next unless assistant&.account_id == conversation.account_id

      Captain::Conversation::ResponseCancellationService.new(conversation: candidate, assistant: assistant, actor: sender)
    end
  end

  def capture_captain_takeover_cancellations(services, generation)
    services.map { |service| [service, service.snapshot(control_generation: generation)] }
  rescue Redis::BaseError => e
    log_captain_cancellation_failure(e)
    []
  end

  def publish_captain_takeover_cancellations
    Array(@captain_takeover_cancellations).each do |service, snapshot|
      service.perform(reason: 'employee_reply', snapshot: snapshot)
    rescue Redis::BaseError => e
      log_captain_cancellation_failure(e)
    end
    @captain_takeover_cancellations = nil
  end

  def log_captain_cancellation_failure(error)
    Rails.logger.warn("[CAPTAIN][Control] Response cancellation unavailable conversation_id=#{conversation.id} error_class=#{error.class.name}")
  end

  def captain_auto_open_candidate?
    captain_pending_conversation? && captain_human_control_candidate?
  end

  def captain_human_control_candidate?
    captain_public_human_reply? && ::CaptainInbox.exists?(inbox_id: conversation.inbox_id)
  end

  def captain_public_human_reply?
    human_response? &&
      !private? &&
      !scheduled_touch_message? &&
      !template_bootstrap_message?
  end

  def captain_pending_conversation?
    return false unless conversation.pending?

    ::CaptainInbox.exists?(inbox_id: conversation.inbox_id)
  end

  def template_bootstrap_message?
    additional_attributes['template_params'].present? &&
      !conversation.messages.incoming.exists?
  end

  def create_captain_auto_open_activity_message
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: I18n.t('conversations.activity.captain.auto_opened_after_agent_reply')
    )
  end

  def without_current_actor
    previous_user = Current.user
    previous_executed_by = Current.executed_by
    Current.user = nil
    Current.executed_by = nil

    yield
  ensure
    Current.user = previous_user
    Current.executed_by = previous_executed_by
  end
end
