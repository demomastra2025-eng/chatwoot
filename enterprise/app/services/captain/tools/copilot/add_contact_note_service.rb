class Captain::Tools::Copilot::AddContactNoteService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_contact_note'
  end

  description 'Add a note to the current conversation contact'
  param :note, type: :string, desc: 'The note content', required: true

  def execute(note:)
    created_note = conversation_operations.add_contact_note(note: note)
    formatted_payload(
      action: 'add_contact_note',
      contact_id: current_contact.id,
      contact_name: current_contact.name,
      note_id: created_note.id,
      note: created_note.content,
      created_at: created_note.created_at&.iso8601
    )
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
