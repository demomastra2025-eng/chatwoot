class Captain::Conversation::RunFenceService
  STALE_CHECKS = {
    assistant_missing: :assistant_missing?,
    conversation_missing: :conversation_missing?,
    assistant_changed: :assistant_changed?,
    human_response_committed: :human_response_committed?,
    human_control: :human_control?,
    control_generation_changed: :control_generation_changed?,
    status_changed: :status_changed?,
    last_message_changed: :last_message_changed?,
    buffer_state_changed: :buffer_state_changed?
  }.freeze

  def initialize(assistant:, state:)
    @assistant = assistant
    @state = state.to_h.with_indifferent_access
    @fence = @state[:captain_response_fence].to_h.with_indifferent_access
  end

  def ensure_current!
    return if fence.blank?

    reason = stale_reason
    return if reason.blank?

    publish_fenced(reason)
    raise Captain::Conversation::ControlGenerationStaleError, "Captain response run is stale: #{reason}"
  end

  private

  attr_reader :assistant, :state, :fence

  def stale_reason
    STALE_CHECKS.find { |_reason, predicate| send(predicate) }&.first&.to_s&.presence
  end

  def assistant_missing?
    assistant.blank?
  end

  def conversation_missing?
    conversation.blank?
  end

  def assistant_changed?
    conversation.inbox.captain_assistant&.id != assistant.id
  end

  def human_control?
    conversation.captain_human_control_active?
  end

  def human_response_committed?
    Captain::Conversation::ControlService.human_response_after?(conversation, fence[:last_message_id])
  end

  def control_generation_changed?
    !control_generation_current?
  end

  def status_changed?
    !conversation_allows_captain_response?
  end

  def last_message_changed?
    !last_message_current?
  end

  def buffer_state_changed?
    !buffer_state_current?
  end

  def conversation
    @conversation ||= Conversation.where(account_id: state[:account_id]).find_by(id: state.dig(:conversation, :id))
  end

  def control_generation_current?
    conversation.captain_control_generation.to_i == fence[:control_generation].to_i
  end

  def conversation_allows_captain_response?
    return true if conversation.pending?
    return false unless conversation.open?

    conversation.inbox.captain_inbox&.reply_to_open_conversations? || false
  end

  def last_message_current?
    return true if fence[:last_message_id].blank?

    latest_incoming_message_id.to_i == fence[:last_message_id].to_i
  end

  def latest_incoming_message_id
    conversation.messages.incoming.reorder(created_at: :desc, id: :desc).pick(:id)
  end

  def buffer_state_current?
    return true if fence[:buffer_token].blank?

    current_buffer_state[:token] == fence[:buffer_token] &&
      current_buffer_state[:assistant_id].to_i == assistant.id &&
      current_buffer_state[:last_message_id].to_i == fence[:last_message_id].to_i &&
      current_buffer_state[:control_generation].to_i == fence[:control_generation].to_i
  end

  def current_buffer_state
    @current_buffer_state ||= JSON.parse(Redis::Alfred.get(buffer_state_key).to_s).with_indifferent_access
  rescue JSON::ParserError
    {}.with_indifferent_access
  end

  def buffer_state_key
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
  end

  def publish_fenced(reason)
    Llm::EventBus.publish(
      'captain.run.fenced',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      assistant_id: state[:assistant_id],
      conversation_id: state.dig(:conversation, :id),
      expected_control_generation: fence[:control_generation],
      actual_control_generation: conversation&.captain_control_generation,
      expected_last_message_id: fence[:last_message_id],
      expected_buffer_token: fence[:buffer_token],
      reason: reason,
      stage: 'tool_execution'
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][RunFence] Failed to publish fence event: #{e.class}: #{e.message}")
  end
end
