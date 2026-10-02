module Enterprise::Message::OrphanPendingHandoff
  private

  def activate_captain_human_control_for_human_response
    reset_captain_takeover_context
    return activate_linked_captain_human_control if captain_public_human_reply? && captain_inbox_involved?
  end

  def activate_linked_captain_human_control
    services = nil
    before_control_save = lambda do
      next unless services&.any?

      @captain_takeover_control_applied = true
      @captain_takeover_control_owner = captain_control_owner_identity
      @captain_takeover_control_generation = conversation.captain_control_owner.captain_control_generation
    end
    conversation.activate_captain_human_control!(
      source: 'agent_reply', actor: sender, before_control_save: before_control_save
    ) do |generation|
      services = captain_takeover_cancellation_services
      @captain_takeover_cancellations = capture_captain_takeover_cancellations(services, generation)
      services.any?
    end
  end

  def reset_captain_takeover_context
    @captain_takeover_cancellations = nil
    @captain_takeover_control_applied = false
    @captain_takeover_control_owner = nil
    @captain_takeover_control_generation = nil
  end

  def captain_control_owner_identity
    owner = conversation.captain_control_owner
    [owner.class.name, owner.id]
  end

  def activate_orphan_pending_human_control_after_commit
    already_activated_owner = @captain_takeover_control_owner if @captain_takeover_control_applied
    already_activated_generation = @captain_takeover_control_generation if @captain_takeover_control_applied
    conversation.activate_captain_human_control!(
      source: incoming? ? 'customer_message' : 'agent_reply',
      actor: sender,
      previously_activated_owner: already_activated_owner,
      previously_activated_generation: already_activated_generation,
      fresh_control_owner: true,
      before_control_save: -> { open_orphan_pending_conversation_for_human_activity_under_lock }
    ) do
      orphan_pending_handoff_trigger?
    end
  end

  def orphan_pending_handoff_trigger?
    return false if conversation.inbox.api? || imported_history_message?
    return false if incoming? && runtime_events_suppressed?
    return false unless orphan_pending_handoff_candidate?

    orphan_pending_customer_message? || captain_public_human_reply?
  end

  def orphan_pending_handoff_candidate?
    conversation.pending? && !conversation.ai_pending_handler_present?(fresh_inbox: true)
  end

  def orphan_pending_customer_message?
    incoming? &&
      sender.is_a?(Contact) &&
      !private? &&
      !voice_call? &&
      !ai_voice_transcript_turn? &&
      !imported_history_message?
  end

  def imported_history_message?
    ActiveModel::Type::Boolean.new.cast(message_attributes_hash(content_attributes)['imported_history'])
  end

  def open_orphan_pending_conversation_for_human_activity_under_lock
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'open' },
      source: 'system'
    ).perform
    conversation.saved_change_to_status?
  end
end
