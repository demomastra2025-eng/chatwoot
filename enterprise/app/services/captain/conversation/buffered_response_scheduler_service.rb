class Captain::Conversation::BufferedResponseSchedulerService
  STATE_TTL_BUFFER = 10.minutes

  def initialize(conversation:, message:, attachment_wait_time: 0.seconds)
    @conversation = conversation
    @message = message
    @attachment_wait_time = attachment_wait_time
  end

  def perform
    token = SecureRandom.uuid
    control_generation = @conversation.stamp_captain_control_generation!(@message)

    Redis::Alfred.set(state_key, state_payload(token, control_generation).to_json, ex: state_ttl_seconds)

    Rails.logger.info(
      '[CAPTAIN][BufferedResponse] Scheduled response builder ' \
      "conversation_id=#{@conversation.id} " \
      "message_id=#{@message.id} wait_seconds=#{effective_wait_seconds}"
    )

    Captain::Conversation::ResponseBuilderJob
      .set(wait: effective_wait_seconds.seconds)
      .perform_later(
        @conversation,
        buffer_token: token,
        expected_last_message_id: @message.id
      )
  end

  private

  def collapse_window_seconds
    Captain::AccountSettings.new(@conversation.account).message_collapse_window_seconds
  end

  def effective_wait_seconds
    [collapse_window_seconds, @attachment_wait_time.to_i].max
  end

  def state_ttl_seconds
    effective_wait_seconds + STATE_TTL_BUFFER.to_i
  end

  def state_payload(token, control_generation)
    {
      token: token,
      last_message_id: @message.id,
      control_generation: control_generation
    }
  end

  def state_key
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: @conversation.id)
  end
end
