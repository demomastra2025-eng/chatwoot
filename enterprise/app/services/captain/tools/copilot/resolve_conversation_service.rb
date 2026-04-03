class Captain::Tools::Copilot::ResolveConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'resolve_conversation'
  end

  description 'Resolve the current conversation'

  def execute
    conversation = conversation_operations.resolve_conversation
    "Resolved conversation ##{conversation.display_id}"
  rescue StandardError => e
    e.message
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
