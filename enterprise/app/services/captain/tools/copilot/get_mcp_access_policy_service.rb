# frozen_string_literal: true

class Captain::Tools::Copilot::GetMcpAccessPolicyService < Captain::Tools::Copilot::McpAccessPolicyTool
  def self.name
    'get_mcp_access_policy'
  end

  description 'Get the current OneLink MCP access policy, source/group summary, and optional visible tool catalog'
  param :include_tools,
        type: :boolean,
        desc: 'Set true to include the visible MCP tool catalog. Defaults to false to keep responses compact.',
        required: false

  def execute(include_tools: false)
    ensure_account_administrator!

    formatted_payload(
      action: 'get_mcp_access_policy',
      mcp: mcp_access_policy_payload(include_tools: include_tools)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
