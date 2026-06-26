class Captain::Tools::Copilot::HandoffService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'handoff'
  end

  description 'Hand off the current conversation to a human team'
  param :reason, type: :string, desc: 'Optional handoff reason for the human team', required: false
  param :status_reason, type: :string, desc: 'Configured conversation status reason for opening/handoff when status reasons are enabled',
                        required: false

  def execute(reason: nil, status_reason: nil)
    conversation = conversation_operations.handoff(reason: reason, status_reason: status_reason)
    resolved_status_reason = latest_status_transition_reason(conversation, 'open')
    formatted_payload(
      action: 'handoff',
      conversation_id: conversation.id,
      conversation_display_id: conversation.display_id,
      status: conversation.status,
      waiting_since: conversation.waiting_since&.iso8601,
      reason: reason,
      status_reason: resolved_status_reason
    ).presence
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
