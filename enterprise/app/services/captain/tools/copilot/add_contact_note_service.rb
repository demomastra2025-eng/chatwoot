class Captain::Tools::Copilot::AddContactNoteService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_contact_note'
  end

  description 'Add a note to the current conversation contact'
  param :note, type: :string, desc: 'The note content', required: true

  def execute(note:)
    created_note = conversation_operations.add_contact_note(note: note)
    "Added contact note ##{created_note.id} to #{current_contact.name}"
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_conversation.present? && user_has_permission('contact_manage')
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
