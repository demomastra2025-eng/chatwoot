class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  description 'Hand off the conversation to a human agent when unable to assist further'
  param :reason, type: 'string', desc: 'The reason why handoff is needed (optional)', required: false

  def perform(tool_context, reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    request_handoff(tool_context, reason)

    # Log the handoff with reason
    log_tool_usage('tool_handoff', {
                     conversation_id: conversation.id,
                     reason: reason || 'Agent requested handoff'
                   })

    halt("Conversation handed off to human support team#{" (Reason: #{reason})" if reason}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    tool_failure('Failed to handoff conversation')
  end

  private

  def request_handoff(tool_context, reason)
    tool_context.context[:pending_human_handoff] = {
      reason: reason.presence,
      timestamp: Time.current
    }
  end

  # TODO: Future enhancement - Add team assignment capability
  # This tool could be enhanced to:
  # 1. Accept team_id parameter for routing to specific teams
  # 2. Set conversation priority based on handoff reason
  # 3. Add metadata for intelligent agent assignment
  # 4. Support escalation levels (L1 -> L2 -> L3)
  #
  # Example future signature:
  # param :team_id, type: 'string', desc: 'ID of team to assign conversation to', required: false
  # param :priority, type: 'string', desc: 'Priority level (low/medium/high/urgent)', required: false
  # param :escalation_level, type: 'string', desc: 'Support level (L1/L2/L3)', required: false
end
