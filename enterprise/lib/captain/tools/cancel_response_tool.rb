class Captain::Tools::CancelResponseTool < Captain::Tools::BasePublicTool
  description 'Silently cancel the current AI response when no customer reply is needed'
  param :reason, type: 'string', desc: 'Optional internal reason for cancelling the response', required: false

  def perform(tool_context, reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    request_response_cancellation(tool_context, reason)
    log_tool_usage('tool_cancel_response', {
                     conversation_id: conversation.id,
                     reason: reason.presence || 'Agent cancelled response'
                   })

    halt('response_cancelled')
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    tool_failure('Failed to cancel response')
  end

  private

  def request_response_cancellation(tool_context, reason)
    tool_context.context[:pending_response_cancellation] = {
      reason: reason.presence,
      timestamp: Time.current
    }.compact
  end
end
