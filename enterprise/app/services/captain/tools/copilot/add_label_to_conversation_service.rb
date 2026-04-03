class Captain::Tools::Copilot::AddLabelToConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_label_to_conversation'
  end

  description 'Add an existing label to the current conversation'
  param :label_name, type: :string, desc: 'The label name', required: true

  def execute(label_name:)
    conversation = conversation_operations.add_label(label_name: label_name)
    "Added label to conversation ##{conversation.display_id}"
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
