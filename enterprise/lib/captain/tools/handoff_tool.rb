class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  CONSENT_REQUIRED_ERROR = (
    'Handoff requires an explicit request for a human or direct consent to the latest handoff question.'
  ).freeze

  description 'Hand off the current conversation to a human team'
  param :reason, type: 'string', desc: 'Optional handoff reason for the human team', required: false
  param :status_reason, type: 'string', desc: 'Configured conversation status reason for opening/handoff when status reasons are enabled',
                        required: false
  param :message, type: 'string', desc: 'Optional customer-facing handoff message to send when AI handoff message mode is enabled', required: false

  def perform(tool_context, reason: nil, status_reason: nil, message: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    if assistant.handoff_requires_explicit_consent?
      return reject_unauthorized_handoff(conversation) unless handoff_authorized?(conversation, tool_context.state)

      reason = assistant.handoff_consent_reason_value
      status_reason = nil
    end

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
                     reason: 'explicit_consent_required'
                   })
    tool_failure(CONSENT_REQUIRED_ERROR)
  end

  def handoff_authorized?(conversation, state)
    Captain::Tools::HandoffConsentPolicy.new(
      assistant: assistant,
      conversation: conversation,
      state: state
    ).authorized?
  end

  def request_handoff(tool_context, reason, status_reason, message)
    tool_context.context[:pending_human_handoff] = {
      reason: reason.presence,
      status_reason: status_reason.presence,
      message: message.presence,
      timestamp: Time.current
    }.compact
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
