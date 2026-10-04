class Captain::Tools::ResolveConversationTool < Captain::Tools::BasePublicTool
  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: 'string', desc: 'Optional reason for resolving the conversation', required: false
  param :status_reason, type: 'string', desc: 'Configured conversation outcome reason for resolving', required: false
  param :outcome_reason_id, type: 'string', desc: 'Configured completion outcome reason ID', required: false

  def perform(tool_context, reason: nil, status_reason: nil, outcome_reason_id: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation
    return "Conversation ##{conversation.display_id} is already resolved" if conversation.resolved?
    return 'Automatic completion is disabled for this assistant' unless assistant.auto_completion_enabled?
    return 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?

    log_tool_usage('resolve_conversation', { conversation_id: conversation.id, reason: reason })

    params = { status: 'resolved' }
    outcome_config = Captain::OutcomeReasonConfig.new(assistant)
    configured = outcome_config.configured?(:completion)
    selected_reason = outcome_config.resolve(:completion, outcome_reason_id.presence || status_reason) if configured
    return tool_failure('A configured completion reason is required') if configured && selected_reason.blank?

    begin
      audit_options = outcome_config.transition_options(:completion, selected_reason, explanation: reason) if configured
      audit = audit_options&.fetch(:audit, {})
    rescue ArgumentError => e
      return tool_failure(e.message)
    end
    resolved_status_reason = if configured
                               selected_reason['label']
                             else
                               configured_status_reason_for(conversation, 'resolved', status_reason,
                                                            fallback_reason: reason)
                             end
    params[:status_reason] = resolved_status_reason if resolved_status_reason.present?

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
        status_reason: resolved_status_reason,
        outcome_reason_id: selected_reason&.fetch('id', nil)
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
