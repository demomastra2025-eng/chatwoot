class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  AUTHORIZED_CONTEXT_KEY = :captain_v2_handoff_authorized_tool_call

  description 'Hand off the current conversation to a human team'
  param :reason, type: 'string', desc: 'Optional handoff reason for the human team', required: false

  # The customer-facing text of a handoff is written by Captain::CustomerNoticeService from the workspace settings, so
  # the agent is no longer asked for a `message`; one from an older tool call is accepted with the legacy options and ignored.
  def perform(tool_context, reason: nil, **_legacy_options)
    unless assistant.handoff_enabled? && assistant.selected_agent_tool_ids.include?('handoff')
      return tool_failure('Handoff tool is not enabled for this assistant')
    end

    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    # Log the handoff with reason
    log_tool_usage('tool_handoff', {
                     conversation_id: conversation.id,
                     reason: reason || 'Agent requested handoff'
                   })
    request_handoff(tool_context, reason)

    halt("Conversation handed off to human support team#{" (Reason: #{reason})" if reason}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    tool_failure('Failed to handoff conversation')
  end

  private

  def request_handoff(tool_context, reason)
    faq_result = tool_context.context[:captain_faq_outcome].to_h
    faq_miss = faq_result[:assistant_id] == assistant.id && faq_result[:result] == 'not_found' && !faq_result[:unavailable]
    tool_context.context[:pending_human_handoff] = {
      reason: reason.presence,
      outcome_signal: faq_miss ? 'faq_no_answer' : nil,
      timestamp: Time.current
    }.compact
    tool_context.context[AUTHORIZED_CONTEXT_KEY] = true
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
