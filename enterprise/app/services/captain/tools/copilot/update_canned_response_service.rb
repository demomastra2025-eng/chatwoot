# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCannedResponseService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'update_canned_response'
  end

  description 'Update a canned response short code or content in the current account'
  param :canned_response_id, type: :integer, desc: 'Canned response ID from search_canned_responses', required: true
  param :short_code, type: :string, desc: 'New unique short code', required: false
  param :content, type: :string, desc: 'New response body', required: false

  def execute(canned_response_id:, short_code: nil, content: nil)
    ensure_account_administrator!

    response = canned_response!(canned_response_id)
    attrs = {}
    attrs[:short_code] = short_code.to_s.strip if short_code.present?
    attrs[:content] = content.to_s.strip if content.present?
    raise ArgumentError, 'At least one field is required' if attrs.blank?

    response.update!(attrs)

    formatted_payload(
      action: 'update_canned_response',
      canned_response: canned_response_payload(response)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
