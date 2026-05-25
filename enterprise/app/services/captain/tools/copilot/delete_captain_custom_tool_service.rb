# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCaptainCustomToolService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'delete_captain_custom_tool'
  end

  description 'Delete an account-scoped Captain custom HTTP tool after operator confirmation'
  param :tool_id, type: :integer, desc: 'Captain custom tool ID', required: true

  def execute(tool_id:)
    ensure_account_administrator!

    custom_tool = find_custom_tool!(tool_id)
    before_payload = custom_tool_payload(custom_tool, include_details: true)
    custom_tool.destroy!

    formatted_payload(action: 'delete_captain_custom_tool', deleted_custom_tool: before_payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
