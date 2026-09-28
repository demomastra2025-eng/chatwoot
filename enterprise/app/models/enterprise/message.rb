module Enterprise::Message
  private

  def activate_captain_human_control_for_human_response
    return unless captain_public_human_reply?

    conversation.activate_captain_human_control!(source: 'agent_reply', actor: sender) do |generation|
      services = captain_takeover_cancellation_services
      @captain_takeover_cancellations = capture_captain_takeover_cancellations(services, generation)
      services.any?
    end
  end

  def mark_pending_conversation_as_open_for_human_response
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
    publish_captain_takeover_cancellations
  end

  def captain_takeover_cancellation_services
    thread = conversation.communication_thread
    conversations = thread ? thread.conversations.where(account_id: conversation.account_id).pending : [conversation].select(&:pending?)
    conversations.filter_map do |candidate|
      assistant = candidate.inbox.captain_assistant
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
