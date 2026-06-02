# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateMcpAccessPolicyService < Captain::Tools::Copilot::McpAccessPolicyTool
  def self.name
    'update_mcp_access_policy'
  end

  description 'Update the current OneLink MCP access policy after operator confirmation. ' \
              'Prefer access_mode: basic or full for normal configuration; use detailed fields only for advanced overrides.'
  param :enabled, type: :boolean, desc: 'Optional toggle for the whole account MCP endpoint', required: false
  param :access_mode,
        type: :string,
        desc: 'Optional simple access mode: basic or full',
        required: false
  param :max_risk_level,
        type: :string,
        desc: 'Optional advanced internal ceiling: low, medium, high, or custom',
        required: false
  param :require_confirmation_for_mutations,
        type: :boolean,
        desc: 'Optional toggle requiring _confirm for OpenAPI mutation fallback tools',
        required: false
  param :captain_tools_enabled,
        type: :boolean,
        desc: 'Optional toggle for native Captain semantic tools in MCP',
        required: false
  param :openapi_read_tools_enabled,
        type: :boolean,
        desc: 'Optional toggle for read-only OpenAPI fallback tools in MCP',
        required: false
  param :openapi_write_tools_enabled,
        type: :boolean,
        desc: 'Optional toggle for mutating OpenAPI fallback tools in MCP. Keep disabled unless explicitly needed.',
        required: false
  param :allowed_groups,
        type: :array,
        desc: 'Optional allow-list of group keys such as captain:Account or openapi:Contacts. Empty array allows all groups not blocked.',
        required: false
  param :blocked_groups,
        type: :array,
        desc: 'Optional block-list of group keys such as captain:Account or openapi:Contacts',
        required: false
  param :allowed_tool_ids,
        type: :array,
        desc: 'Optional explicit allow-list of native Captain tool IDs. Empty array uses risk/group policy.',
        required: false
  param :blocked_tool_ids,
        type: :array,
        desc: 'Optional block-list of native Captain tool IDs',
        required: false
  param :allowed_openapi_operation_ids,
        type: :array,
        desc: 'Optional explicit allow-list of OpenAPI operation IDs. Empty array uses risk/group policy.',
        required: false
  param :blocked_openapi_operation_ids,
        type: :array,
        desc: 'Optional block-list of OpenAPI operation IDs',
        required: false
  param :include_tools,
        type: :boolean,
        desc: 'Set true to include the visible MCP tool catalog in the response after saving. Defaults to false.',
        required: false

  def execute(**kwargs)
    ensure_account_administrator!

    config, updated_fields = mcp_access_update_attributes(kwargs)
    raise ArgumentError, 'No supported MCP access policy fields were provided' if updated_fields.blank?

    account.mcp_access = config
    account.save!

    formatted_payload(
      action: 'update_mcp_access_policy',
      mcp: mcp_access_policy_payload(include_tools: kwargs[:include_tools]),
      updated_fields: updated_fields
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
