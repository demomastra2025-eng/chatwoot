class Captain::Conversation::ControlService # rubocop:disable Metrics/ClassLength
  AI_CONTROL = 'ai'.freeze
  HUMAN_CONTROL = 'human'.freeze

  def self.human_response_after?(conversation, message_id)
    return false if message_id.blank?

    contact_messages_scope(conversation).outgoing.where(private: false).where('messages.id > ?', message_id).find_each.any? do |message|
      message.send(:human_response?) && !message.send(:scheduled_touch_message?) && !message.send(:template_bootstrap_message?)
    end
  end

  def self.contact_messages_scope(conversation)
    return conversation.messages if conversation.contact_id.blank?

    conversations = ::Conversation.where(account_id: conversation.account_id, contact_id: conversation.contact_id).select(:id)
    Message.where(account_id: conversation.account_id, conversation_id: conversations)
  end

  def self.messages_scope(conversation)
    thread = conversation.communication_thread
    return conversation.messages unless thread

    Message.where(conversation_id: thread.conversations.select(:id))
  end

  def initialize(conversation)
    @conversation = conversation
  end

  def stamp_generation!(message)
    with_control_lock do
      generation = control_owner.captain_control_generation.to_i
      message.with_lock do
        attributes = message.additional_attributes.to_h
        next if attributes.key?('captain_control_generation') && attributes['captain_control_generation'].to_i == generation

        # This internal fence must not trigger message-updated broadcasts or provider callbacks.
        message.update_column(:additional_attributes, attributes.merge('captain_control_generation' => generation)) # rubocop:disable Rails/SkipsModelValidations
      end
      generation
    end
  end

  def activate_human!(source:, actor: nil)
    changed = false
    with_control_lock do
      unless human_active?
        claim_human_control!
        changed = true
      end
    end

    publish('captain.control.human_activated', source: source, actor: actor) if changed
    changed
  end

  # Called only by the deliberate Contact owner-change callback. That callback
  # already holds Contact and the routing Team; acquiring the advisory here
  # would invert an advisor-first writer waiting for Contact. The caller owns
  # every contact Thread before it starts projecting Conversation rows.
  def activate_human_after_contact_lock!(source:, actor:)
    changed = false
    control_owner.with_lock do
      unless human_active?
        claim_human_control!
        changed = true
      end
    end
    publish('captain.control.human_activated', source: source, actor: actor) if changed
    changed
  end

  def prepare_ai!
    changed = false
    with_control_lock do
      next unless human_active?

      control_owner.captain_control_state = AI_CONTROL
      control_owner.captain_control_generation += 1
      control_owner.captain_handoff_applied_at = nil
      control_owner.save!
      changed = true
    end
    changed
  end

  def with_control_lock(&)
    ActiveRecord::Base.transaction do
      Conversations::CommunicationThreadResolver.lock_contact_thread!(conversation.account_id, conversation.contact_id)
      # An unlinked handoff may refresh into an existing contact Thread after
      # changing status. Acquire those rows before locking its Conversation.
      if conversation.communication_thread.blank?
        CommunicationThread.where(account_id: conversation.account_id, contact_id: conversation.contact_id).order(:id).lock.load
      end
      persist_control_owner!
      control_owner.with_lock(&)
    end
  end

  def handoff!(status_reason:, actor:, source:, audit: {}, fence: nil, &)
    publish('captain.handoff.requested', source: source, actor: actor)
    result = apply_handoff(status_reason: status_reason, actor: actor, source: source, audit: audit, fence: fence, &)
    event_name = handoff_event_name(result)
    publish(event_name, source: source, actor: actor)
    result
  rescue StandardError => e
    publish('captain.handoff.failed', source: source, actor: actor, error_class: e.class.name)
    raise
  end

  def publish_ai_activated!(source:, actor: nil)
    publish('captain.control.ai_activated', source: source, actor: actor)
  end

  private

  attr_reader :conversation

  def control_owner
    @control_owner ||= conversation.captain_control_owner
  end

  def persist_control_owner!
    control_owner.save! if control_owner.new_record? || control_owner.has_changes_to_save?
  end

  def human_active?
    control_owner.captain_control_state == HUMAN_CONTROL
  end

  def apply_handoff(status_reason:, actor:, source:, audit:, fence:, &callback)
    result = :already_applied
    # Contact advisory -> shared owner -> channel conversation, including inline Thread refresh.
    with_control_lock do
      with_locked_conversation_preserving_changes do
        result = apply_handoff_under_lock(status_reason: status_reason, actor: actor, source: source, audit: audit, fence: fence, &callback)
      end
    end

    result
  end

  def with_locked_conversation_preserving_changes
    pending_attributes = conversation.attributes.slice(*conversation.changed_attribute_names_to_save.excluding('status'))
    conversation.restore_attributes
    conversation.with_lock do
      @control_owner = nil
      conversation.assign_attributes(pending_attributes)
      yield
    end
  end

  def apply_handoff_under_lock(status_reason:, actor:, source:, audit:, fence:)
    return :stale if handoff_stale?(fence)
    return :already_applied if handoff_already_applied?

    apply_handoff_transition!(status_reason: status_reason, actor: actor, source: source, audit: audit)
    yield if block_given?
    :applied
  end

  def apply_handoff_transition!(status_reason:, actor:, source:, audit:)
    conversation.waiting_since ||= Time.current
    claim_human_control!(handoff: true)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'open', status_reason: status_reason },
      actor: actor,
      source: source,
      audit: audit
    ).perform
  end

  def handoff_stale?(fence)
    expected = fence.to_h.with_indifferent_access
    return false if expected.blank?
    return true unless conversation_allows_captain_response?
    return true if expected[:control_generation].present? && control_owner.captain_control_generation.to_i != expected[:control_generation].to_i
    return true if incoming_message_changed?(expected[:last_message_id])

    self.class.human_response_after?(conversation, expected[:last_message_id])
  end

  def incoming_message_changed?(last_message_id)
    return false if last_message_id.blank?

    incoming = self.class.contact_messages_scope(conversation).incoming
    return true if incoming.exists?(['messages.id > ?', last_message_id.to_i])

    incoming.reorder(created_at: :desc, id: :desc).pick(:id).to_i != last_message_id.to_i
  end

  def conversation_allows_captain_response?
    return true if conversation.pending?
    return false unless conversation.open?

    conversation.inbox.captain_inbox&.reply_to_open_conversations? || false
  end

  def handoff_event_name(result)
    {
      applied: 'captain.handoff.applied',
      stale: 'captain.handoff.skipped_stale'
    }.fetch(result, 'captain.handoff.skipped_duplicate')
  end

  def handoff_already_applied?
    return true if human_active?
    return false unless human_assigned?

    activate_human_for_existing_assignment!
    true
  end

  def human_assigned?
    conversation.assignee_id.present?
  end

  def activate_human_for_existing_assignment!
    claim_human_control!
  end

  def claim_human_control!(handoff: false)
    control_owner.captain_control_state = HUMAN_CONTROL
    control_owner.captain_control_generation += 1
    control_owner.captain_handoff_applied_at = Time.current if handoff
    control_owner.save!
    Captain::Conversation::PendingActionCancellationService.new(conversation: conversation, control_owner: control_owner).perform
  end

  def publish(event_name, source:, actor: nil, error_class: nil)
    Llm::EventBus.publish(
      event_name,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: conversation.account_id,
      conversation_id: conversation.id,
      communication_thread_id: conversation.communication_thread&.id,
      source: source,
      actor_type: actor&.class&.name,
      actor_id: actor&.id,
      control_state: control_owner.captain_control_state,
      control_generation: control_owner.captain_control_generation,
      error_class: error_class
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Control] Failed to publish #{event_name}: #{e.class}: #{e.message}")
  end
end
