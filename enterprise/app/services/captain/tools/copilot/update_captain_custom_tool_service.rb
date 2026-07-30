# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainCustomToolService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'update_captain_custom_tool'
  end

  description 'Update an account-scoped Captain custom HTTP tool after operator confirmation'
  param :tool_id, type: :integer, desc: 'Captain custom tool ID', required: true
  param :title, type: :string, desc: 'Optional updated title', required: false
  param :description, type: :string, desc: 'Optional updated description', required: false
  param :endpoint_url, type: :string, desc: 'Optional updated endpoint URL or Liquid URL template', required: false
  param :http_method, type: :string, desc: 'Optional updated HTTP method', required: false
  param :group_name, type: :string, desc: 'Optional updated group name', required: false
  param :request_template, type: :string, desc: 'Optional updated Liquid request body template', required: false
  param :response_template, type: :string, desc: 'Optional updated Liquid response template', required: false
  param :auth_type, type: :string, desc: 'Optional updated auth type: none, bearer, basic, or api_key', required: false
  param :auth_config_json,
        type: :string,
        desc: 'Optional JSON object for auth config; sensitive values are redacted in previews/audit',
        required: false
  param :http_options_json,
        type: :string,
        desc: 'Optional JSON object for bounded timeout, retry, redirect, idempotency, pagination, and batching options',
        required: false
  param :param_schema_json, type: :string, desc: 'Optional JSON array of parameter schema entries', required: false
  param :enabled, type: :boolean, desc: 'Optional enabled status', required: false
  param :allow_file_artifacts, type: :boolean, desc: 'Optional file artifact access flag', required: false

  def execute(tool_id:, **kwargs)
    ensure_account_administrator!

    custom_tool = find_custom_tool!(tool_id)
    attributes = update_custom_tool_attributes(kwargs)
    raise ArgumentError, 'No supported custom tool fields were provided' if attributes.blank?

    before_payload = custom_tool_payload(custom_tool, include_details: true)
    custom_tool.update!(attributes)

    formatted_payload(
      action: 'update_captain_custom_tool',
      custom_tool: custom_tool_payload(custom_tool.reload, include_details: true),
      previous_custom_tool: before_payload,
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
