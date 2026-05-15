class Captain::Tools::Copilot::RemoveLabelFromConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'remove_label_from_conversation'
  end

  description 'Remove a label from the current or specified account conversation'
  param :conversation_id, type: :integer, desc: 'Optional conversation display ID or internal ID', required: false
  param :label_name, type: :string, desc: 'The label name to remove', required: true

  def execute(label_name:, conversation_id: nil)
    conversation = conversation_operations.remove_label(label_name: label_name, conversation_id: conversation_id)

    formatted_payload(
      action: 'remove_label_from_conversation',
      conversation_id: conversation.display_id,
      label_name: label_name.to_s.strip.downcase,
      labels: conversation.label_list.to_a
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
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
