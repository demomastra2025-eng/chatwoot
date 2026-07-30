# frozen_string_literal: true

class Captain::Tools::Copilot::CreateCaptainCustomToolService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'create_captain_custom_tool'
  end

  description 'Create an account-scoped Captain custom HTTP tool after operator confirmation'
  param :title, type: :string, desc: 'Custom tool title', required: true
  param :description, type: :string, desc: 'Custom tool description', required: false
  param :endpoint_url, type: :string, desc: 'Endpoint URL or Liquid URL template', required: true
  param :http_method, type: :string, desc: 'HTTP method. Defaults to GET.', required: false
  param :group_name, type: :string, desc: 'Optional group name shown in tool catalogs', required: false
  param :request_template, type: :string, desc: 'Optional Liquid request body template', required: false
  param :response_template, type: :string, desc: 'Optional Liquid response template', required: false
  param :auth_type, type: :string, desc: 'Authentication type: none, bearer, basic, or api_key', required: false
  param :auth_config_json, type: :string, desc: 'JSON object for auth config; sensitive values are redacted in previews/audit', required: false
  param :http_options_json,
        type: :string,
        desc: 'Optional JSON object for bounded timeout, retry, redirect, idempotency, pagination, and batching options',
        required: false
  param :param_schema_json, type: :string, desc: 'JSON array of parameter schema entries', required: false
  param :enabled, type: :boolean, desc: 'Whether the tool is enabled. Defaults to true.', required: false
  param :allow_file_artifacts, type: :boolean, desc: 'Whether the tool may use file artifacts. Defaults to true.', required: false

  def execute(title:, endpoint_url:, **kwargs)
    ensure_account_administrator!

    custom_tool = account.captain_custom_tools.create!(create_custom_tool_attributes(kwargs.merge(title: title, endpoint_url: endpoint_url)))

    formatted_payload(
      action: 'create_captain_custom_tool',
      custom_tool: custom_tool_payload(custom_tool.reload, include_details: true)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
