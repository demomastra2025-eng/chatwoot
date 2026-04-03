class Captain::Tools::Copilot::HandoffService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'handoff'
  end

  description 'Hand off the current conversation to a human team'
  param :reason, type: :string, desc: 'Optional handoff reason', required: false

  def execute(reason: nil)
    conversation = conversation_operations.handoff(reason: reason)
    "Handed off conversation ##{conversation.display_id}"
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
