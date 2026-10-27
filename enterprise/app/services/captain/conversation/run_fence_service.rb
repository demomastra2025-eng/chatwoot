# Tells whether a run of the AI is still current. The run belongs to a channel (Captain::ChannelScope), not to an agent: it goes stale
# when the channel is switched off or its AI is off, a human answers, the conversation changes, or the acting agent (state[:assistant_id],
# none for an output that no agent produced) is switched off or taken out of the channel. Turning off another agent never stales a run.
class Captain::Conversation::RunFenceService
  STALE_CHECKS = {
    assistant_missing: :assistant_missing?,
    conversation_missing: :conversation_missing?,
    channel_changed: :channel_changed?,
    agent_routing_changed: :agent_routing_changed?,
    human_response_committed: :human_response_committed?,
    control_generation_changed: :control_generation_changed?,
    status_epoch_changed: :status_epoch_changed?,
    status_changed: :status_changed?,
    last_message_changed: :last_message_changed?,
    buffer_state_changed: :buffer_state_changed?
  }.freeze

  # assistant: the acting agent, nil when no agent acts (the state carries no assistant_id either).
  def initialize(assistant:, state:, stage: 'tool_execution')
    @assistant = assistant
    @state = state.to_h.with_indifferent_access
    @fence = @state[:captain_response_fence].to_h.with_indifferent_access
    @stage = stage
  end

  def ensure_current!
    return if fence.blank?

    reason = stale_reason
    return if reason.blank?

    publish_fenced(reason)
    raise Captain::Conversation::ControlGenerationStaleError, "Captain response run is stale: #{reason}"
  end

  private

  attr_reader :assistant, :state, :fence, :stage

  def stale_reason
    STALE_CHECKS.find { |_reason, predicate| send(predicate) }&.first&.to_s&.presence
  end

  def assistant_missing?
    return false if acting_agent_id.blank?

    # Another request can disable an actor while inference is still running.
    # Neither the loaded actor nor the request query cache is authoritative here.
    Captain::Assistant.uncached do
      !Captain::Assistant.exists?(account_id: state[:account_id], id: acting_agent_id, active: true)
    end
  end

  def acting_agent_id
    @acting_agent_id ||= (assistant&.id || state[:assistant_id]).presence&.to_i
  end

  def conversation_missing?
    conversation.blank?
  end

  # The channel is switched off (or its AI is off), or the acting agent is no longer an enabled agent of the channel.
  def channel_changed?
    Captain::Assistant.uncached do
      inbox = conversation.inbox.reload
      next true unless inbox.captain_active?

      acting_agent_id.present? && !agent_in_channel?(inbox)
    end
  end

  def agent_in_channel?(inbox)
    scope = Captain::ChannelScope.for_inbox(inbox, account: conversation.account)
    Captain::AgentGraph.new(scope).find(acting_agent_id).present?
  end

  # The fence of a turn that the router decided carries the routing revision (see Captain::Runtime::RoutingState): the agent that
  # holds the conversation and the revision must still be the ones the run started with.
  def agent_routing_changed?
    return false unless acting_agent_id.present? && fence.key?(:routing_revision)

    session = conversation.reload.additional_attributes.to_h[Captain::Conversation::AgentSession::ATTRIBUTE].to_h
    session['current_assistant_id'].to_i != acting_agent_id || session['routing_revision'].to_i != fence[:routing_revision].to_i
  end

  def human_response_committed?
    Captain::Conversation::ControlService.human_response_after?(conversation, fence[:last_message_id])
  end

  def control_generation_changed?
    !control_generation_current?
  end

  def status_epoch_changed?
    return false unless fence.key?(:status_transition_id)

    conversation.status_transitions.maximum(:id).to_i != fence[:status_transition_id].to_i
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
    conversation.current_captain_control_generation.to_i == fence[:control_generation].to_i
  end

  def conversation_allows_captain_response?
    conversation.pending? || resolved_by_captain_tool?
  end

  def resolved_by_captain_tool?
    ActiveModel::Type::Boolean.new.cast(state[:captain_resolved_by_tool]) && conversation.resolved?
  end

  def last_message_current?
    return true if fence[:last_message_id].blank?

    latest_incoming_message_id.to_i == fence[:last_message_id].to_i
  end

  def latest_incoming_message_id
    Captain::Conversation::ControlService.incoming_messages_scope(conversation).reorder(created_at: :desc, id: :desc).pick(:id)
  end

  def buffer_state_current?
    return true if fence[:buffer_token].blank?

    current_buffer_state[:token] == fence[:buffer_token] &&
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
      communication_thread_id: conversation&.communication_thread&.id,
      expected_control_generation: fence[:control_generation],
      actual_control_generation: conversation&.current_captain_control_generation,
      expected_last_message_id: fence[:last_message_id],
      expected_buffer_token: fence[:buffer_token],
      reason: reason,
      stage: stage
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][RunFence] Failed to publish fence event: #{e.class}: #{e.message}")
  end
end
