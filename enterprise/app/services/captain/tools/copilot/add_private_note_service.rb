class Captain::Tools::Copilot::AddPrivateNoteService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_private_note'
  end

  description 'Add a private note to the current conversation'
  param :note, type: :string, desc: 'The private note content', required: true

  def execute(note:)
    message = conversation_operations.add_private_note(note: note)
    "Added private note message ##{message.id} to conversation ##{current_conversation.display_id}"
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
