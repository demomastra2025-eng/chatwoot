class Captain::Conversation::ControlService
  AI_CONTROL = 'ai'.freeze
  HUMAN_CONTROL = 'human'.freeze

  def self.human_response_after?(conversation, message_id)
    return false if message_id.blank?

    contact_messages_scope(conversation).outgoing.where(private: false).where('messages.id > ?', message_id).find_each.any? do |message|
      # The other inbox may not yet be linked (or Captain-enabled), but a
      # human reply to the same contact still invalidates the AI run.
      message.send(:human_response?) && !message.send(:scheduled_touch_message?) && !message.send(:template_bootstrap_message?)
    end
  end

  # An inbound on another channel is visible as soon as it commits, before
  # its after-commit thread resolver links that conversation. The action
  # dispatch fence must inspect the contact under the shared advisory lock.
  def self.contact_messages_scope(conversation)
    return conversation.messages if conversation.contact_id.blank?

    conversations = ::Conversation.where(account_id: conversation.account_id, contact_id: conversation.contact_id).select(:id)
    Message.where(account_id: conversation.account_id, conversation_id: conversations)
  end

  def self.messages_scope(conversation)
    thread = conversation.communication_thread
    thread ? Message.where(conversation_id: thread.conversations.select(:id)) : conversation.messages
  end

  def initialize(conversation)
    @conversation = conversation
  end

  def stamp_generation!(message)
    generation = control_owner.captain_control_generation.to_i
    message.with_lock do
      attributes = message.additional_attributes.to_h
      next if attributes.key?('captain_control_generation') && attributes['captain_control_generation'].to_i == generation

      # This internal fence must not trigger message-updated broadcasts or provider callbacks.
      message.update_column(:additional_attributes, attributes.merge('captain_control_generation' => generation)) # rubocop:disable Rails/SkipsModelValidations
    end
    generation
  end

  def activate_human!(source:, actor: nil)
    changed = false
    persist_control_owner!

    control_owner.with_lock do
      next if human_active?

      claim_human_control!
      changed = true
    end

    publish('captain.control.human_activated', source: source, actor: actor) if changed
    changed
  end

  def prepare_ai!
    changed = false
    persist_control_owner!
    control_owner.with_lock do
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
    persist_control_owner!
    control_owner.with_lock(&)
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
    # Dispatch and human activation lock the shared owner first. Match that
    # order before locking a linked conversation for the handoff transition.
    owner = control_owner
    operation = proc do
      with_locked_conversation_preserving_changes do
        with_control_owner_lock do
          result = apply_handoff_under_lock(status_reason: status_reason, actor: actor, source: source, audit: audit, fence: fence, &callback)
        end
      end
    end
    owner.equal?(conversation) ? operation.call : owner.with_lock(&operation)
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

  def with_control_owner_lock(&)
    return yield if control_owner.equal?(conversation)

    control_owner.with_lock(&)
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

    self.class.human_response_after?(conversation, expected[:last_message_id])
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
