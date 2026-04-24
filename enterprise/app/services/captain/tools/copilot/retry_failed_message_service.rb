class Captain::Tools::Copilot::RetryFailedMessageService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'retry_failed_message'
  end

  description 'Retry delivery for a failed outgoing message'
  param :message_id, type: :integer, desc: 'Failed outgoing message ID', required: true

  def execute(message_id:)
    message = conversation_operations.retry_failed_message(message_id: message_id)

    formatted_payload(
      action: 'retry_failed_message',
      message: {
        id: message.id,
        conversation_id: message.conversation.display_id,
        content: message.content,
        status: message.status,
        external_error: message.external_error,
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
