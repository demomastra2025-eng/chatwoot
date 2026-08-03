# frozen_string_literal: true

class Captain::Tools::GetConfirmationRequestTool < Captain::Tools::BasePublicTool
  description 'Get the latest or a specific confirmation request for the current conversation without exposing its callback token'

  param :confirmation_request_id, type: 'integer', desc: 'Optional confirmation request ID; defaults to the latest request', required: false

  def perform(tool_context, confirmation_request_id: nil)
    conversation = current_conversation(tool_context.state)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    scope = ConfirmationRequest.where(account_id: assistant.account_id, conversation_id: conversation.id)
    request = confirmation_request_id.present? ? scope.find(confirmation_request_id) : scope.order(created_at: :desc, id: :desc).first
    return tool_failure('Confirmation request not found') if request.blank?

    JSON.pretty_generate(
      action: 'get_confirmation_request',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
