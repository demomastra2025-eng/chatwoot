class Captain::Tools::Copilot::SendMessageToConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'send_message_to_conversation'
  end

  description 'Send a message to a conversation the user can access'
  param :conversation_id, type: :integer, desc: 'Conversation display ID', required: true
  param :content, type: :string, desc: 'Message content to send', required: true
  param :private_note, type: :boolean, desc: 'When true, send as a private note instead of a customer-visible message', required: false
  param :in_reply_to_message_id, type: :integer, desc: 'Optional message ID to reply to', required: false

  def execute(conversation_id:, content:, private_note: nil, in_reply_to_message_id: nil)
    message = conversation_operations.send_message_to_conversation(
      conversation_id: conversation_id,
      content: content,
      private_note: private_note,
      in_reply_to_message_id: in_reply_to_message_id
    )

    formatted_payload(
      action: 'send_message_to_conversation',
      conversation_id: message.conversation.display_id,
      message: message_payload(message)
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

  def message_payload(message)
    {
      id: message.id,
      conversation_id: message.conversation.display_id,
      content: message.content,
      private: message.private,
      status: message.status,
      message_type: message.message_type,
      sender_type: message.sender_type,
      sender_id: message.sender_id,
      sender_name: message.sender&.try(:name),
      created_at: message.created_at&.iso8601,
      updated_at: message.updated_at&.iso8601
    }
  end
end
