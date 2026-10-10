class Captain::Conversation::ResponseCancellationService
  STATE_TTL = 10.minutes

  def initialize(conversation:, assistant:, actor: nil)
    @conversation = conversation
    @assistant = assistant
    @actor = actor
  end

  def perform(reason: nil, snapshot: nil)
    return false unless valid_scope?

    payload = (snapshot || self.snapshot).to_h.symbolize_keys
    return false unless snapshot_belongs_to_scope?(payload)

    payload[:cancel_reason] = reason.presence if reason.present?
    published = Redis::Alfred.set_if_newer(
      state_key, payload.to_json, version_key: 'captured_at_us', version: payload.fetch(:captured_at_us), ex: STATE_TTL.to_i
    )
    return false unless published == 1

    clear_typing_indicator
    true
  end

  def snapshot(control_generation: @conversation.current_captain_control_generation)
    buffer = current_buffer_state
    {
      account_id: @conversation.account_id,
      conversation_id: @conversation.id,
      assistant_id: @assistant.id,
      control_generation: control_generation,
      status_transition_id: @conversation.status_transitions.maximum(:id).to_i,
      last_message_id: buffer&.dig('last_message_id').presence || last_incoming_message_id,
      buffer_token: buffer&.dig('token'),
      cancelled_by_id: @actor&.id,
      cancelled_at: Time.current.iso8601,
      captured_at_us: (Time.current.to_r * 1_000_000).to_i
    }.compact
  end

  def cancelled?(**fence)
    return false unless valid_scope?

    state = cancellation_state
    return false unless state_matches?(state, **fence)

    true
  end

  def clear_if_current!(**fence)
    return false unless valid_scope?

    raw_state = Redis::Alfred.get(state_key)
    return false unless state_matches?(parse_state(raw_state), **fence)

    Redis::Alfred.delete_if_value(state_key, raw_state) == 1
  end

  private

  def valid_scope?
    @conversation.present? && @assistant.present? && @conversation.account_id == @assistant.account_id
  end

  def snapshot_belongs_to_scope?(payload)
    payload[:account_id] == @conversation.account_id && payload[:conversation_id] == @conversation.id && payload[:assistant_id] == @assistant.id
  end

  def state_matches?(state, buffer_token: nil, expected_last_message_id: nil, expected_control_generation: nil, expected_status_transition_id: nil)
    return false unless state_belongs_to_scope?(state)
    return false unless epoch_matches?(state, 'control_generation', expected_control_generation)
    return false unless epoch_matches?(state, 'status_transition_id', expected_status_transition_id)
    return false unless token_matches?(state, buffer_token)

    state['last_message_id'].to_i == expected_message_id(expected_last_message_id).to_i
  end

  def state_belongs_to_scope?(state)
    state.present? && state['assistant_id'].to_i == @assistant.id &&
      epoch_matches?(state, 'account_id', @conversation.account_id) && epoch_matches?(state, 'conversation_id', @conversation.id)
  end

  def token_matches?(state, token)
    token.blank? || state['buffer_token'].blank? || state['buffer_token'] == token
  end

  def epoch_matches?(state, key, expected)
    expected.nil? || !state.key?(key) || state[key].to_i == expected.to_i
  end

  def expected_message_id(expected_last_message_id)
    expected_last_message_id.presence || last_incoming_message_id
  end

  def last_incoming_message_id
    @last_incoming_message_id ||= Captain::Conversation::ControlService.incoming_messages_scope(@conversation)
                                                                       .reorder(created_at: :desc, id: :desc).pick(:id)
  end

  def cancellation_state
    parse_state(Redis::Alfred.get(state_key))
  end

  def current_buffer_state
    parse_state(Redis::Alfred.get(buffer_state_key))
  end

  def parse_state(raw_state)
    return if raw_state.blank?

    state = JSON.parse(raw_state)
    state if state.is_a?(Hash)
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
