class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  AUTHORIZED_CONTEXT_KEY = :captain_v2_handoff_authorized_tool_call
  STRICT_HANDOFF_UNAVAILABLE_ERROR = 'Automatic handoff is unavailable until a verified consent policy is enabled.'.freeze

  description 'Hand off the current conversation to a human team'
  param :reason, type: 'string', desc: 'Required concise factual explanation of what happened and why a human is needed.', required: true
  param :status_reason, type: 'string', desc: 'Configured conversation status reason ID for the assistant handoff outcome',
                        required: false
  param :message, type: 'string', desc: 'Optional customer-facing handoff message to send when AI handoff message mode is enabled', required: false

  def perform(tool_context, reason: nil, status_reason: nil, message: nil)
    return 'Handoff to a human is disabled for this assistant' unless assistant.handoff_enabled?
    # Strict mode accepts only a trusted server-side consent event. A tool
    # request must not Halt with a public success message without that event.
    return tool_failure('Human handoff requires explicit consent') if assistant.handoff_requires_explicit_consent?
    return 'A specific handoff explanation is required' if reason.to_s.squish.blank?

    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    return reject_unauthorized_handoff(conversation) if assistant.handoff_requires_explicit_consent?

    # Log the handoff with reason
    log_tool_usage('tool_handoff', {
                     conversation_id: conversation.id,
                     reason: reason || 'Agent requested handoff'
                   })
    request_handoff(tool_context, reason, status_reason, message)

    halt("Conversation handed off to human support team#{" (Reason: #{reason})" if reason}")
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    tool_failure('Failed to handoff conversation')
  end

  private

  def reject_unauthorized_handoff(conversation)
    log_tool_usage('tool_handoff_denied', {
                     conversation_id: conversation.id,
                     reason: 'verified_consent_policy_unavailable'
                   })
    Captain::ToolResult.failure(
      error: STRICT_HANDOFF_UNAVAILABLE_ERROR,
      retryable: false,
      audit: {
        failure_stage: 'authorization',
        failure_reason: 'handoff_not_authorized'
      }
    )
  end

  def request_handoff(tool_context, reason, status_reason, message)
    tool_context.context[:pending_human_handoff] = {
      reason: reason.presence,
      status_reason: status_reason.presence,
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
