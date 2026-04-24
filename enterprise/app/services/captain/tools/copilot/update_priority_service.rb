class Captain::Tools::Copilot::UpdatePriorityService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_priority'
  end

  description 'Update the priority of the current conversation'
  param :priority, type: :string, desc: 'Priority value: low, medium, high, urgent, or none', required: true

  def execute(priority:)
    conversation = conversation_operations.update_priority(priority: priority)
    formatted_payload(
      action: 'update_priority',
      conversation_id: conversation.id,
      conversation_display_id: conversation.display_id,
      priority: conversation.priority
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
