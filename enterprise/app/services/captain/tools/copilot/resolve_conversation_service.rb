class Captain::Tools::Copilot::ResolveConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'resolve_conversation'
  end

  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: :string, desc: 'Required concise factual explanation of why the conversation can be completed.', required: true
  param :status_reason, type: :string, desc: 'Exact configured assistant completion outcome ID', required: false

  def execute(reason: nil, status_reason: nil)
    conversation = conversation_operations.resolve_conversation(reason: reason, status_reason: status_reason)
    resolved_status_reason = latest_status_transition_reason(conversation, 'resolved')
    formatted_payload(
      {
        action: 'resolve_conversation',
        conversation_id: conversation.id,
        conversation_display_id: conversation.display_id,
        status: conversation.status,
        reason: reason,
        status_reason: resolved_status_reason
      }.compact
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_conversation.present? &&
      (user_has_permission('conversation_manage') ||
       user_has_permission('conversation_unassigned_manage') ||
       user_has_permission('conversation_participating_manage'))
  end

  private

  def conversation_operations
    Captain::Tools::Operations::ConversationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

  def latest_status_transition_reason(conversation, target_status)
    conversation.status_transitions.order(created_at: :desc, id: :desc).find_by(to_status: target_status)&.reason
  end
end
