class Captain::Conversation::BufferedResponseFlushJob < MutexApplicationJob
  queue_as :captain_runtime

  retry_on LockAcquisitionError, wait: 1.second, attempts: 5

  # The buffered response belongs to the channel of the conversation, not to an agent. assistant_id is accepted for a job that an
  # earlier release queued, and ignored.
  def perform(conversation_id:, token:, assistant_id: nil) # rubocop:disable Lint/UnusedMethodArgument
    with_lock(lock_key(conversation_id)) do
      state = buffer_state(conversation_id)
      next unless valid_state?(state, token)

      conversation = Conversation.find_by(id: conversation_id)

      unless conversation.present? && should_generate_response?(conversation)
        clear_state(conversation_id, token)
        next
      end

      Captain::Conversation::ResponseBuilderJob.perform_now(
        conversation,
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

  def valid_state?(state, token)
    state.present? && state['token'] == token
  end

  def should_generate_response?(conversation)
    conversation_allows_captain_response?(conversation) &&
      conversation.inbox.captain_active? &&
      conversation.inbox.captain_auto_reply_allowed?
  end

  def conversation_allows_captain_response?(conversation)
    conversation.pending?
  end

  def clear_state(conversation_id, token)
    raw_state = Redis::Alfred.get(state_key(conversation_id))
    state = JSON.parse(raw_state.to_s)
    return unless state.is_a?(Hash) && state['token'] == token

    Redis::Alfred.delete_if_value(state_key(conversation_id), raw_state)
  rescue JSON::ParserError
    nil
  end

  def state_key(conversation_id)
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation_id)
  end

  def lock_key(conversation_id)
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_LOCK, conversation_id: conversation_id)
  end
end
