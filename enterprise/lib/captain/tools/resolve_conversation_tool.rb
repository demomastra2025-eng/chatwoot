class Captain::Tools::ResolveConversationTool < Captain::Tools::BasePublicTool
  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: 'string', desc: 'Optional reason for resolving the conversation', required: false

  def perform(tool_context, reason: nil, **_legacy_options)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation
    return "Conversation ##{conversation.display_id} is already resolved" if conversation.resolved?
    return 'Automatic completion is disabled for this assistant' unless assistant.auto_completion_enabled?
    return 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    log_tool_usage('resolve_conversation', { conversation_id: conversation.id, reason: reason })

    params = { status: 'resolved' }
    outcome_config = Captain::OutcomeReasonConfig.new(assistant)
    audit = outcome_config.pending_transition_options(:completion, explanation: reason).fetch(:audit)
    audit[:metadata][:outcome_run_facts] = Captain::OutcomeFacts.from_run(tool_context.context)

    transition = lambda do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: params,
        actor: assistant,
        source: 'captain',
        audit: audit || {}
      ).perform
    end

    if reason.present?
      conversation.with_captain_activity_context(reason: reason, reason_type: :tool, &transition)
    else
      transition.call
    end
    conversation.reload

    tool_success(
      data: {
        action: 'resolve_conversation',
        conversation_id: conversation.id,
        conversation_display_id: conversation.display_id,
        status: conversation.status,
        reason: reason.presence,
        reason_classification: 'pending'
      }.compact
    )
  end

  private

  def permissions
    %w[conversation_manage conversation_unassigned_manage conversation_participating_manage]
  end

end
