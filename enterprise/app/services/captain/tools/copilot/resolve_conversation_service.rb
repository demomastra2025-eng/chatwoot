class Captain::Tools::Copilot::ResolveConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'resolve_conversation'
  end

  description 'Resolve the current conversation when the issue has been addressed or the conversation should be closed'
  param :reason, type: :string, desc: 'Optional reason for resolving the conversation', required: false

  def execute(reason: nil)
    conversation = conversation_operations.resolve_conversation(reason: reason)
    formatted_payload(
      {
        action: 'resolve_conversation',
        conversation_id: conversation.id,
        conversation_display_id: conversation.display_id,
        status: conversation.status,
        reason: reason
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
end
