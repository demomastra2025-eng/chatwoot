class Captain::Conversation::ResponseCancellationService
  STATE_TTL = 10.minutes

  def initialize(conversation:, assistant:, actor: nil)
    @conversation = conversation
    @assistant = assistant
    @actor = actor
  end

  def perform(reason: nil)
    return false unless @conversation.present? && @assistant.present?

    Redis::Alfred.set(state_key, state_payload(reason).to_json, ex: STATE_TTL.to_i)
    clear_typing_indicator
    true
  end

  def cancelled?(buffer_token: nil, expected_last_message_id: nil)
    state = cancellation_state
    return false unless state_matches?(state, buffer_token: buffer_token, expected_last_message_id: expected_last_message_id)

    true
  end

  def clear_if_current!(buffer_token: nil, expected_last_message_id: nil)
    return false unless cancelled?(buffer_token: buffer_token, expected_last_message_id: expected_last_message_id)

    Redis::Alfred.delete(state_key)
    true
  end

  private

  def state_payload(reason)
    {
      assistant_id: @assistant.id,
      last_message_id: last_incoming_message_id,
      buffer_token: current_buffer_state&.dig('token'),
      cancelled_by_id: @actor&.id,
      cancel_reason: reason.presence,
      cancelled_at: Time.current.iso8601
    }.compact
  end

  def state_matches?(state, buffer_token:, expected_last_message_id:)
    return false if state.blank?
    return false unless state['assistant_id'].to_i == @assistant.id.to_i

    if buffer_token.present?
      return false if state['buffer_token'].present? && state['buffer_token'] != buffer_token

      return state['last_message_id'].to_i == expected_message_id(expected_last_message_id).to_i
    end

    state['last_message_id'].to_i == expected_message_id(expected_last_message_id).to_i
  end

  def expected_message_id(expected_last_message_id)
    expected_last_message_id.presence || last_incoming_message_id
  end

  def last_incoming_message_id
    @last_incoming_message_id ||= @conversation.messages.incoming.last&.id
  end

  def cancellation_state
    raw_state = Redis::Alfred.get(state_key)
    return if raw_state.blank?

    JSON.parse(raw_state)
  rescue JSON::ParserError
    nil
  end

  def current_buffer_state
    raw_state = Redis::Alfred.get(buffer_state_key)
    return if raw_state.blank?

    JSON.parse(raw_state)
  rescue JSON::ParserError
    nil
  end

  def clear_typing_indicator
    Captain::Conversation::TypingIndicatorService.turn_off(
      conversation: @conversation,
      assistant: @assistant
    )
  end

  def state_key
    format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: @conversation.id)
  end

  def buffer_state_key
    format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: @conversation.id)
  end
end
