# frozen_string_literal: true

class Captain::Tools::Copilot::CaptainCustomToolAdminTool < Captain::Tools::Copilot::CaptainAssistantAdminTool
  CUSTOM_TOOL_AUTH_TYPES = %w[none bearer basic api_key].freeze
  CUSTOM_TOOL_HTTP_METHODS = Captain::CustomTool::HTTP_METHODS.freeze
  TEMPLATE_FIELDS = %w[request_template response_template].freeze
  SIMPLE_UPDATE_FIELDS = %i[
    title group_name description endpoint_url request_template response_template enabled allow_file_artifacts
  ].freeze

  private

  def custom_tools_scope
    account.captain_custom_tools.order(updated_at: :desc)
  end

  def find_custom_tool!(tool_id)
    custom_tools_scope.find(tool_id)
  end

  def custom_tool_payload(custom_tool, include_details: false)
    payload = custom_tool_identity_payload(custom_tool).merge(custom_tool_status_payload(custom_tool))
    merge_custom_tool_details!(payload, custom_tool) if include_details
    payload.compact
  end

  def custom_tool_identity_payload(custom_tool)
    {
      id: custom_tool.id,
      slug: custom_tool.slug,
      title: redacted_value(custom_tool.title),
      group_name: redacted_value(custom_tool.group_name),
      description: redacted_value(custom_tool.description),
      created_at: custom_tool.created_at&.iso8601,
      updated_at: custom_tool.updated_at&.iso8601
    }
  end

  def custom_tool_status_payload(custom_tool)
    {
      enabled: custom_tool.enabled,
      http_method: custom_tool.http_method,
      auth_type: custom_tool.auth_type,
      allow_file_artifacts: custom_tool.allow_file_artifacts,
      endpoint_configured: custom_tool.endpoint_url.present?,
      request_template_configured: custom_tool.request_template.present?,
      response_template_configured: custom_tool.response_template.present?,
      param_count: custom_tool.parameter_definitions.size
    }
  end

  def merge_custom_tool_details!(payload, custom_tool)
    payload.merge!(custom_tool_endpoint_payload(custom_tool))
    payload.merge!(custom_tool_template_payload(custom_tool))
    payload[:auth_config] = redacted_auth_config(custom_tool)
    payload[:param_schema] = filtered_marker(custom_tool.param_schema)
    payload[:param_schema_bytes] = JSON.generate(custom_tool.param_schema || []).bytesize
  end

  def custom_tool_endpoint_payload(custom_tool)
    {
      endpoint_url: filtered_marker(custom_tool.endpoint_url),
      endpoint_url_bytes: custom_tool.endpoint_url.to_s.bytesize.presence
    }
  end

  def custom_tool_template_payload(custom_tool)
    TEMPLATE_FIELDS.each_with_object({}) do |field, memo|
      value = custom_tool.public_send(field)
      memo[field.to_sym] = filtered_marker(value)
      memo["#{field}_bytes".to_sym] = value.to_s.bytesize if value.present?
    end
  end

  def filtered_marker(value)
    value.present? ? '[FILTERED]' : nil
  end

  def tool_failure(error, retryable: nil)
    super(redacted_error(error), retryable: retryable)
  end

  def redacted_error(error)
    return error unless error.respond_to?(:message)

    error.class.new(redacted_value(error.message))
  rescue StandardError
    ArgumentError.new('[FILTERED]')
  end

  def redacted_auth_config(custom_tool)
    return {} if custom_tool.auth_none?

    custom_tool.auth_config.to_h.transform_values { '[FILTERED]' }
  end

  def create_custom_tool_attributes(kwargs)
    {
      title: kwargs[:title],
      group_name: kwargs[:group_name],
      description: kwargs[:description],
      endpoint_url: kwargs[:endpoint_url],
      http_method: normalized_http_method(kwargs[:http_method]),
      request_template: kwargs[:request_template],
      response_template: kwargs[:response_template],
      auth_type: normalized_auth_type(kwargs[:auth_type]),
      auth_config: parse_json_hash(kwargs[:auth_config_json], field_name: 'auth_config_json', default: {}),
      param_schema: parse_json_array(kwargs[:param_schema_json], field_name: 'param_schema_json', default: []),
      enabled: cast_boolean(kwargs[:enabled], default: true),
      allow_file_artifacts: cast_boolean(kwargs[:allow_file_artifacts], default: true)
    }.compact
  end

  def update_custom_tool_attributes(kwargs)
    attributes = SIMPLE_UPDATE_FIELDS.each_with_object({}) do |field, memo|
      next unless kwargs.key?(field)

      memo[field] = normalized_simple_update_value(field, kwargs[field])
    end

    attributes[:http_method] = normalized_http_method(kwargs[:http_method]) if kwargs.key?(:http_method)
    attributes[:auth_type] = normalized_auth_type(kwargs[:auth_type]) if kwargs.key?(:auth_type)
    attributes[:auth_config] = parsed_auth_config(kwargs) if kwargs.key?(:auth_config_json)
    attributes[:param_schema] = parsed_param_schema(kwargs) if kwargs.key?(:param_schema_json)
    attributes
  end

  def normalized_simple_update_value(field, value)
    return cast_boolean(value) if %i[enabled allow_file_artifacts].include?(field)

    value
  end

  def parsed_auth_config(kwargs)
    parse_json_hash(kwargs[:auth_config_json], field_name: 'auth_config_json', default: {})
  end

  def parsed_param_schema(kwargs)
    parse_json_array(kwargs[:param_schema_json], field_name: 'param_schema_json', default: [])
  end

  def normalized_http_method(http_method)
    method = http_method.to_s.presence || 'GET'
    raise ArgumentError, "http_method must be one of: #{CUSTOM_TOOL_HTTP_METHODS.join(', ')}" unless CUSTOM_TOOL_HTTP_METHODS.include?(method)

    method
  end

  def normalized_auth_type(auth_type)
    type = auth_type.to_s.presence || 'none'
    raise ArgumentError, "auth_type must be one of: #{CUSTOM_TOOL_AUTH_TYPES.join(', ')}" unless CUSTOM_TOOL_AUTH_TYPES.include?(type)

    type
  end
end
