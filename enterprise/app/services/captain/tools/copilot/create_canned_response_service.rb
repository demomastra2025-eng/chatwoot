class Captain::Tools::Copilot::CreateCannedResponseService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_canned_response'
  end

  description 'Create a reusable canned response'
  param :short_code, type: :string, desc: 'Unique canned response short code', required: true
  param :content, type: :string, desc: 'Response body', required: true

  def execute(short_code:, content:)
    canned_response = account.canned_responses.create!(
      short_code: short_code.to_s.strip,
      content: content.to_s.strip
    )

    formatted_payload(
      action: 'create_canned_response',
      canned_response: {
        id: canned_response.id,
        short_code: canned_response.short_code,
        content: canned_response.content,
        created_at: canned_response.created_at&.iso8601,
        updated_at: canned_response.updated_at&.iso8601
      }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_account_user.present?
  end
end
