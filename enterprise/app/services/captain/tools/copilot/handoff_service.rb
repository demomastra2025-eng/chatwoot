class Captain::Tools::Copilot::HandoffService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'handoff'
  end

  description 'Hand off the current conversation to a human team'
  param :reason, type: :string, desc: 'Optional handoff reason for the human team', required: false

  def execute(reason: nil)
    conversation = conversation_operations.handoff(reason: reason)
    formatted_payload(
      action: 'handoff',
      conversation_id: conversation.id,
      conversation_display_id: conversation.display_id,
      status: conversation.status,
      waiting_since: conversation.waiting_since&.iso8601,
      reason: reason
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
end
