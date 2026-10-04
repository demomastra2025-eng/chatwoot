class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  AUTHORIZED_CONTEXT_KEY = :captain_v2_handoff_authorized_tool_call

  description 'Hand off the current conversation to a human team'
  param :reason, type: 'string', desc: 'Optional handoff reason for the human team', required: false
  param :status_reason, type: 'string', desc: 'Configured conversation outcome reason for handoff', required: false
  param :outcome_reason_id, type: 'string', desc: 'Configured handoff outcome reason ID', required: false
  param :message, type: 'string', desc: 'Optional customer-facing handoff message to send when AI handoff message mode is enabled', required: false

  def perform(tool_context, reason: nil, status_reason: nil, outcome_reason_id: nil, message: nil)
    unless assistant.handoff_enabled? && assistant.selected_agent_tool_ids.include?('handoff')
      return tool_failure('Handoff tool is not enabled for this assistant')
    end

    outcome_config = Captain::OutcomeReasonConfig.new(assistant)
    configured = outcome_config.configured?(:handoff)
    selected_reason = outcome_config.resolve(:handoff, outcome_reason_id.presence || status_reason) if configured
    return tool_failure('A configured handoff reason is required') if configured && selected_reason.blank?
    if configured && outcome_config.explanation_required?(:handoff, candidate: selected_reason['id'], explanation: reason)
      return tool_failure('Provide a specific explanation when choosing Other')
    end

    status_reason = selected_reason['label'] if selected_reason

    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    # Log the handoff with reason
    log_tool_usage('tool_handoff', {
                     conversation_id: conversation.id,
                     reason: reason || 'Agent requested handoff'
                   })
    request_handoff(tool_context, reason, status_reason, selected_reason&.fetch('id', nil), message)

    halt("Conversation handed off to human support team#{" (Reason: #{reason})" if reason}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    tool_failure('Failed to handoff conversation')
  end

  private

  def request_handoff(tool_context, reason, status_reason, outcome_reason_id, message)
    tool_context.context[:pending_human_handoff] = {
      reason: reason.presence,
      status_reason: status_reason.presence,
      outcome_reason_id: outcome_reason_id.presence,
      message: message.presence,
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
