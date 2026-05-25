class Captain::Tools::Copilot::CreateCannedResponseService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'create_canned_response'
  end

  description 'Create a reusable canned response in the current account'
  param :short_code, type: :string, desc: 'Unique canned response short code', required: true
  param :content, type: :string, desc: 'Response body', required: true

  def execute(short_code:, content:)
    ensure_account_administrator!

    canned_response = account.canned_responses.create!(
      short_code: short_code.to_s.strip,
      content: content.to_s.strip
    )

    formatted_payload(
      action: 'create_canned_response',
      canned_response: canned_response_payload(canned_response)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
