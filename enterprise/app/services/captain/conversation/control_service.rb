class Captain::Conversation::ControlService
  AI_CONTROL = 'ai'.freeze
  HUMAN_CONTROL = 'human'.freeze

  def self.human_response_after?(conversation, message_id)
    return false if message_id.blank?

    conversation.messages.outgoing.where(private: false).where('messages.id > ?', message_id).find_each.any? do |message|
      message.send(:captain_human_control_candidate?)
    end
  end

  def initialize(conversation)
    @conversation = conversation
  end

  def stamp_generation!(message)
    generation = conversation.captain_control_generation.to_i
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
    conversation.save! if conversation.has_changes_to_save?

    conversation.with_lock do
      next if human_active?

      conversation.captain_control_state = HUMAN_CONTROL
      conversation.captain_control_generation += 1
      conversation.save!
      changed = true
    end

    publish('captain.control.human_activated', source: source, actor: actor) if changed
    changed
  end

  def prepare_ai!
    return false unless human_active?

    conversation.captain_control_state = AI_CONTROL
    conversation.captain_control_generation += 1
    conversation.captain_handoff_applied_at = nil
    true
  end

  def handoff!(status_reason:, actor:, source:, fence: nil, &)
    publish('captain.handoff.requested', source: source, actor: actor)
    result = apply_handoff(status_reason: status_reason, actor: actor, source: source, fence: fence, &)
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

  def human_active?
    conversation.captain_control_state == HUMAN_CONTROL
  end

  def apply_handoff(status_reason:, actor:, source:, fence:, &)
    result = :already_applied
    conversation.save! if conversation.has_changes_to_save?

    conversation.with_lock do
      if handoff_stale?(fence)
        result = :stale
        next
      end
      next if handoff_already_applied?

      apply_handoff_transition!(status_reason: status_reason, actor: actor, source: source)
      yield if block_given?
      result = :applied
    end

    result
  end

  def apply_handoff_transition!(status_reason:, actor:, source:)
    conversation.waiting_since ||= Time.current
    conversation.captain_control_state = HUMAN_CONTROL
    conversation.captain_control_generation += 1
    conversation.captain_handoff_applied_at = Time.current
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'open', status_reason: status_reason },
      actor: actor,
      source: source
    ).perform
  end

  def handoff_stale?(fence)
    expected = fence.to_h.with_indifferent_access
    return false if expected.blank?
    return true if expected[:control_generation].present? && conversation.captain_control_generation.to_i != expected[:control_generation].to_i

    self.class.human_response_after?(conversation, expected[:last_message_id])
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
    conversation.captain_control_state = HUMAN_CONTROL
    conversation.captain_control_generation += 1
    conversation.save!
  end

  def publish(event_name, source:, actor: nil, error_class: nil)
    Llm::EventBus.publish(
      event_name,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: conversation.account_id,
      conversation_id: conversation.id,
      source: source,
      actor_type: actor&.class&.name,
      actor_id: actor&.id,
      control_state: conversation.captain_control_state,
      control_generation: conversation.captain_control_generation,
      error_class: error_class
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Control] Failed to publish #{event_name}: #{e.class}: #{e.message}")
  end
end
