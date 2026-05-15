# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCannedResponseService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'delete_canned_response'
  end

  description 'Delete a canned response from the current account'
  param :canned_response_id, type: :integer, desc: 'Canned response ID from search_canned_responses', required: true

  def execute(canned_response_id:)
    ensure_account_administrator!

    response = canned_response!(canned_response_id)
    payload = canned_response_payload(response)
    response.destroy!

    formatted_payload(
      action: 'delete_canned_response',
      deleted: true,
      canned_response: payload
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
