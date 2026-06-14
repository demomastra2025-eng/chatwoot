class Captain::Conversation::BufferedResponseFlushJob < MutexApplicationJob
  queue_as :captain_runtime

  retry_on LockAcquisitionError, wait: 1.second, attempts: 5

  def perform(conversation_id:, assistant_id:, token:)
    with_lock(lock_key(conversation_id)) do
      state = buffer_state(conversation_id)
      next unless valid_state?(state, assistant_id, token)

      conversation = Conversation.find_by(id: conversation_id)
      assistant = Captain::Assistant.find_by(id: assistant_id)

      unless conversation.present? && assistant.present? && should_generate_response?(conversation, assistant)
        clear_state(conversation_id, token)
        next
      end

      Captain::Conversation::ResponseBuilderJob.perform_now(
        conversation,
        assistant,
        buffer_token: token,
        expected_last_message_id: state['last_message_id']
      )
    end
  end

  private

  def buffer_state(conversation_id)
    raw_state = Redis::Alfred.get(state_key(conversation_id))
    return if raw_state.blank?

    JSON.parse(raw_state)
  rescue JSON::ParserError
    nil
  end

  def valid_state?(state, assistant_id, token)
    state.present? &&
      state['assistant_id'].to_i == assistant_id.to_i &&
      state['token'] == token
  end

  def should_generate_response?(conversation, assistant)
    conversation_allows_captain_response?(conversation) &&
      conversation.inbox.captain_active? &&
      conversation.inbox.captain_auto_reply_allowed? &&
      conversation.inbox.captain_assistant&.id == assistant.id
  end

  def conversation_allows_captain_response?(conversation)
    return true if conversation.pending?
    return false unless conversation.open?

    conversation.inbox.captain_inbox&.reply_to_open_conversations? || false
  end

  def clear_state(conversation_id, token)
    state = buffer_state(conversation_id)
    return unless state.present? && state['token'] == token

    Redis::Alfred.delete(state_key(conversation_id))
  end

  def state_key(conversation_id)
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation_id)
  end

  def lock_key(conversation_id)
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_LOCK, conversation_id: conversation_id)
  end
end
