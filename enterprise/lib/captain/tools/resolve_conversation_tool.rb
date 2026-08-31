class Captain::Tools::ResolveConversationTool < Captain::Tools::BasePublicTool
  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: 'string', desc: 'Required concise factual explanation of why the conversation can be completed.', required: true
  param :status_reason, type: 'string', desc: 'Exact configured assistant completion outcome ID', required: false

  def perform(tool_context, reason: nil, status_reason: nil)
    return 'Automatic completion is disabled for this assistant' unless assistant.auto_completion_enabled?
    return 'A specific completion explanation is required' if reason.to_s.squish.blank?
    if Captain::OutcomeReasonConfig.new(assistant).explanation_required?(
      :completion,
      candidate: status_reason,
      explanation: reason
    )
      return 'A specific completion explanation is required'
    end

    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation
    return "Conversation ##{conversation.display_id} is already resolved" if conversation.resolved?
    return 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    log_tool_usage('resolve_conversation', { conversation_id: conversation.id, reason: reason })
    resolved_status_reason = transition_conversation(conversation, reason, status_reason)
    resolution_success(conversation.reload, reason, resolved_status_reason)
  end

  private

  def transition_conversation(conversation, reason, status_reason)
    params, transition_options, resolved_status_reason = resolution_transition_attributes(reason, status_reason)
    perform_status_transition(conversation, params, transition_options, reason)
    resolved_status_reason
  end

  def perform_status_transition(conversation, params, transition_options, reason)
    transition = lambda do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: params,
        actor: assistant,
        source: 'captain',
        **transition_options
      ).perform
    end

    if reason.present?
      conversation.with_captain_activity_context(reason: reason, reason_type: :tool, &transition)
    else
      transition.call
    end
  end

  def resolution_transition_attributes(reason, status_reason)
    params = { status: 'resolved' }
    resolved_reason, options = resolved_reason_and_transition_options(status_reason, explanation: reason)
    params[:status_reason] = resolved_reason if resolved_reason.present? && options.empty?
    [params, options, resolved_reason]
  end

  def resolution_success(conversation, reason, resolved_status_reason)
    tool_success(
      data: {
        action: 'resolve_conversation',
        conversation_id: conversation.id,
        conversation_display_id: conversation.display_id,
        status: conversation.status,
        reason: reason.presence,
        status_reason: resolved_status_reason
      }.compact
    )
  end

  def permissions
    %w[conversation_manage conversation_unassigned_manage conversation_participating_manage]
  end

  def resolved_reason_and_transition_options(explicit_reason, explanation: nil)
    outcome_config = Captain::OutcomeReasonConfig.new(assistant)
    outcome_reason = outcome_config.resolve(:completion, explicit_reason)
    [
      outcome_reason&.fetch('label'),
      outcome_config.transition_options(:completion, outcome_reason, explanation: explanation)
    ]
  end
end
