class Captain::Tools::Account::CancelResponseService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'cancel_response'
  end

  description 'Silently cancel the current AI response for the active conversation'
  param :reason, type: :string, desc: 'Optional internal reason for cancelling the response', required: false

  def execute(reason: nil)
    conversation = current_conversation
    return tool_failure('Conversation not found') unless conversation

    Captain::Conversation::ResponseCancellationService.new(conversation: conversation, actor: @user).perform(reason: reason)

    formatted_payload(
      action: 'cancel_response',
      response_cancelled: true,
      conversation_id: conversation.id,
      conversation_display_id: conversation.display_id,
      reason: reason.presence
    ).presence
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_conversation.present?
  end
end
