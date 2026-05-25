# frozen_string_literal: true

class Captain::Tools::Copilot::GetCaptainCustomToolService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'get_captain_custom_tool'
  end

  description 'Get one account-scoped Captain custom HTTP tool with sensitive config redacted'
  param :tool_id, type: :integer, desc: 'Captain custom tool ID', required: true

  def execute(tool_id:)
    ensure_account_administrator!

    formatted_payload(
      action: 'get_captain_custom_tool',
      custom_tool: custom_tool_payload(find_custom_tool!(tool_id), include_details: true)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
