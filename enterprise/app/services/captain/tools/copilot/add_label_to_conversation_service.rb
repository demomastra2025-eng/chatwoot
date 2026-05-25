class Captain::Tools::Copilot::AddLabelToConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_label_to_conversation'
  end

  description 'Add an existing label to the current or specified account conversation'
  param :conversation_id, type: :integer, desc: 'Optional conversation display ID or internal ID', required: false
  param :label_name, type: :string, desc: 'The label name', required: true

  def execute(label_name:, conversation_id: nil)
    conversation = conversation_operations.add_label(label_name: label_name, conversation_id: conversation_id)
    formatted_payload(
      action: 'add_label_to_conversation',
      conversation_id: conversation.id,
      conversation_display_id: conversation.display_id,
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
