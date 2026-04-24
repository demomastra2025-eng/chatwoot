class Captain::Tools::Copilot::EditMessageService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'edit_message'
  end

  description 'Edit an existing outgoing message when the channel supports message editing'
  param :message_id, type: :integer, desc: 'Message ID to edit', required: true
  param :content, type: :string, desc: 'Updated message content', required: true

  def execute(message_id:, content:)
    message = conversation_operations.edit_message(message_id: message_id, content: content)

    formatted_payload(
      action: 'edit_message',
      message: {
        id: message.id,
        conversation_id: message.conversation.display_id,
        content: message.content,
        status: message.status,
        content_attributes: message.content_attributes,
        updated_at: message.updated_at&.iso8601
      }
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
