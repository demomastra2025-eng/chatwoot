# frozen_string_literal: true

# Serializes a Captain action with the human takeover on the same control-owner
# row. A check performed before the tool call alone is not sufficient: a
# takeover may commit before the tool reaches its provider or database write.
class Captain::Conversation::ActionFenceService
  ORIGIN_KEY = :captain_action_origin

  def self.current_origin
    ActiveSupport::IsolatedExecutionState[ORIGIN_KEY]
  end

  def initialize(assistant:, state:)
    @assistant = assistant
    @state = state.to_h.with_indifferent_access
  end

  def with_effect!(&)
    fence = @state[:captain_response_fence]
    return yield if fence.blank? && @state.dig(:conversation, :id).blank?

    conversation = ::Conversation.where(account_id: @state[:account_id]).find_by(id: @state.dig(:conversation, :id))
    raise Captain::Conversation::ControlGenerationStaleError, 'Captain conversation is missing before action' if conversation.blank?

    ::Conversation.transaction do
      lock_contact_before_owner!(conversation)
      conversation.captain_control_owner.with_lock do
        ensure_current!(conversation, fence)
        with_origin(conversation, fence, &)
      end
    end
  end

  private

  def lock_contact_before_owner!(conversation)
    return if conversation.contact_id.blank?

    # Inline assignment re-enters the resolver, which takes the contact
    # advisory lock before the owner row (also for unlinked conversations).
    Conversations::CommunicationThreadResolver.lock_contact_thread!(conversation.account_id, conversation.contact_id)
  end

  def ensure_current!(conversation, fence)
    return ensure_legacy_generation!(conversation) if fence.blank?

    Captain::Conversation::RunFenceService.new(assistant: @assistant, state: @state, stage: 'tool_effect').ensure_current!
  end

  def with_origin(conversation, fence)
    previous_origin = self.class.current_origin
    generation = fence.present? ? fence[:control_generation] || fence['control_generation'] : @state[:captain_control_generation]
    ActiveSupport::IsolatedExecutionState[ORIGIN_KEY] = {
      'assistant_id' => @assistant&.id,
      'conversation_id' => conversation.id,
      'control_generation' => generation
    }
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[ORIGIN_KEY] = previous_origin
  end

  def ensure_legacy_generation!(conversation)
    expected = @state[:captain_control_generation]
    assistant_changed = @assistant.blank? || conversation.inbox.captain_assistant&.id != @assistant.id
    invalid_generation = conversation.current_captain_control_generation.to_i != expected.to_i
    return unless expected.nil? || assistant_changed || conversation.captain_human_control_active? || invalid_generation

    raise Captain::Conversation::ControlGenerationStaleError, 'Captain control changed before action'
  end
end
