class Captain::Tools::ResolveConversationTool < Captain::Tools::BasePublicTool
  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: 'string', desc: 'Optional reason for resolving the conversation', required: false
  param :status_reason, type: 'string', desc: 'Configured conversation status reason for resolving when status reasons are enabled', required: false

  def perform(tool_context, reason: nil, status_reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation
    return "Conversation ##{conversation.display_id} is already resolved" if conversation.resolved?
    return 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    log_tool_usage('resolve_conversation', { conversation_id: conversation.id, reason: reason })

    params = { status: 'resolved' }
    resolved_status_reason = configured_status_reason_for(conversation, 'resolved', status_reason, fallback_reason: reason)
    params[:status_reason] = resolved_status_reason if resolved_status_reason.present?

    transition = lambda do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: params,
        actor: assistant,
        source: 'captain'
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
        status_reason: resolved_status_reason
      }.compact
    )
  end

  private

  def permissions
    %w[conversation_manage conversation_unassigned_manage conversation_participating_manage]
  end

  def configured_status_reason_for(conversation, target_status, explicit_reason, fallback_reason: nil)
    config = Conversations::StatusReasonConfig.new(conversation.account)
    explicit_reason = explicit_reason.to_s.strip.presence
    return config.resolve_reason!(target_status, explicit_reason, enforce_required: false) if explicit_reason.present?

    config.canonical_reason(target_status, fallback_reason)
  end
end
