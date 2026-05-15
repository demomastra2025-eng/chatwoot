# frozen_string_literal: true

class Captain::Tools::Copilot::SetCaptainCustomToolStatusService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'set_captain_custom_tool_status'
  end

  description 'Enable or disable an account-scoped Captain custom HTTP tool after operator confirmation'
  param :tool_id, type: :integer, desc: 'Captain custom tool ID', required: true
  param :enabled, type: :boolean, desc: 'Whether the custom tool should be enabled', required: true

  def execute(tool_id:, enabled:)
    ensure_account_administrator!

    custom_tool = find_custom_tool!(tool_id)
    before_payload = custom_tool_payload(custom_tool, include_details: true)
    custom_tool.update!(enabled: cast_boolean(enabled))

    formatted_payload(
      action: 'set_captain_custom_tool_status',
      custom_tool: custom_tool_payload(custom_tool.reload, include_details: true),
      previous_custom_tool: before_payload,
      updated_fields: ['enabled']
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
