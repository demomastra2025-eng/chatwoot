# frozen_string_literal: true

class Captain::Tools::Copilot::GetCannedResponseService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'get_canned_response'
  end

  description 'Get one canned response in the current account'
  param :canned_response_id, type: :integer, desc: 'Canned response ID from search_canned_responses', required: true

  def execute(canned_response_id:)
    ensure_account_administrator!

    response = canned_response!(canned_response_id)

    formatted_payload(
      action: 'get_canned_response',
      canned_response: canned_response_payload(response)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
