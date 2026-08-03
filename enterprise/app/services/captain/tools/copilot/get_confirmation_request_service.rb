# frozen_string_literal: true

class Captain::Tools::Copilot::GetConfirmationRequestService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_confirmation_request'
  end

  description 'Get the latest or a specific confirmation request visible to the current operator without exposing its callback token'

  param :confirmation_request_id,
        type: :integer,
        desc: 'Optional confirmation request ID; defaults to the latest request in the current conversation',
        required: false

  def execute(confirmation_request_id: nil)
    scope = permissible_confirmation_requests
    request = confirmation_request_id.present? ? scope.find_by(id: confirmation_request_id) : latest_request(scope)
    return tool_failure('Confirmation request not found') if request.blank?

    formatted_payload(
      action: 'get_confirmation_request',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request)
    )
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def permissible_confirmation_requests
    conversation_ids = Conversations::PermissionFilterService.new(account.conversations, @user, account).perform.select(:id)
    ConfirmationRequest.where(account_id: account.id, conversation_id: conversation_ids)
  end

  def latest_request(scope)
    return if @conversation.blank?

    scope.where(conversation_id: @conversation.id).order(created_at: :desc, id: :desc).first
  end
end
