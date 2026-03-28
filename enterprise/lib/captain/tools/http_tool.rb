require 'agents'

class Captain::Tools::HttpTool < Agents::Tool
  class MissingRequiredParametersError < StandardError; end
  class ToolConfigurationError < StandardError; end

  def initialize(assistant, custom_tool)
    @assistant = assistant
    @custom_tool = custom_tool
    super()
  end

  def active?
    @custom_tool.enabled?
  end

  def perform(tool_context, **params)
    state = tool_context&.state || {}
    request_params = resolve_request_params(params, state)
    template_context = build_template_context(request_params, state)
    url = @custom_tool.build_request_url(request_params, template_context: template_context)
    body = @custom_tool.build_request_body(request_params, template_context: template_context)

    response = execute_http_request(url, body, tool_context)
    @custom_tool.format_response(response.body)
  rescue MissingRequiredParametersError => e
    Rails.logger.warn("HttpTool missing parameters for #{@custom_tool.slug}: #{e.message}")
    e.message
  rescue ToolConfigurationError => e
    Rails.logger.error("HttpTool configuration error for #{@custom_tool.slug}: #{e.message}")
    'The tool could not run because it is misconfigured'
  rescue StandardError => e
    Rails.logger.error("HttpTool execution error for #{@custom_tool.slug}: #{e.class} - #{e.message}")
    'An error occurred while executing the request'
  end

  private

  PRIVATE_IP_RANGES = [
    IPAddr.new('127.0.0.0/8'),    # IPv4 Loopback
    IPAddr.new('10.0.0.0/8'),     # IPv4 Private network
    IPAddr.new('172.16.0.0/12'),  # IPv4 Private network
    IPAddr.new('192.168.0.0/16'), # IPv4 Private network
    IPAddr.new('169.254.0.0/16'), # IPv4 Link-local
    IPAddr.new('::1'),            # IPv6 Loopback
    IPAddr.new('fc00::/7'),       # IPv6 Unique local addresses
    IPAddr.new('fe80::/10')       # IPv6 Link-local
  ].freeze

  # Limit response size to prevent memory exhaustion and match LLM token limits
  # 1MB of text ≈ 250K tokens, which exceeds most LLM context windows
  MAX_RESPONSE_SIZE = 1.megabyte

  def build_template_context(params, state)
    stringified_params = params.deep_stringify_keys
    prompt_context = build_prompt_context_for_templates(state)

    {
      'params' => stringified_params,
      'p' => stringified_params,
      'contact' => prompt_context['contact'] || {},
      'conversation' => prompt_context['conversation'] || {},
      'assistant' => assistant_template_context,
      'account' => account_template_context,
      'visible_fields' => prompt_context['visible_fields'] || {}
    }.merge(stringified_params)
  end

  def resolve_request_params(params, state)
    raw_params = params.deep_stringify_keys
    parameter_definitions = @custom_tool.parameter_definitions
    resolved_params = parameter_definitions.each_with_object({}) do |param_definition, memo|
      memo[param_definition['name']] = resolve_param_value(param_definition, raw_params, state)
    end

    resolved_params.merge!(raw_params.except(*parameter_definitions.map { |param_definition| param_definition['name'] }))
    validate_required_params!(resolved_params)
    resolved_params
  end

  def resolve_param_value(param_definition, raw_params, state)
    source = param_definition['source']

    raw_value = case source
                when Captain::CustomTool::PARAM_SOURCE_CONTEXT
                  resolve_context_value(param_definition, state)
                when Captain::CustomTool::PARAM_SOURCE_FIXED
                  resolve_fixed_value(param_definition)
                else
                  raw_params[param_definition['name']]
                end

    Captain::CustomTool.cast_param_value(param_definition['type'], raw_value)
  rescue ArgumentError => e
    raise ToolConfigurationError, "parameter #{param_definition['name']} #{e.message}" if source == Captain::CustomTool::PARAM_SOURCE_FIXED

    raise MissingRequiredParametersError, "The tool could not run because #{param_definition['name']} is invalid"
  end

  def resolve_context_value(param_definition, state)
    prompt_context = build_prompt_context_for_templates(state)
    Captain::ContextFields.value_for_field_id(prompt_context, param_definition['context_path'])
  end

  def resolve_fixed_value(param_definition)
    param_definition['fixed_value']
  end

  def validate_required_params!(resolved_params)
    missing_params = @custom_tool.parameter_definitions.filter_map do |param_definition|
      next unless param_definition.fetch('required', false)
      next if param_value_present?(resolved_params[param_definition['name']])

      param_definition['name']
    end

    return if missing_params.empty?

    raise MissingRequiredParametersError, missing_params_message(missing_params)
  end

  def param_value_present?(value)
    return false if value.nil?
    return value.present? if value.is_a?(String)
    return value.any? if value.is_a?(Array)
    return value.any? if value.is_a?(Hash)

    true
  end

  def missing_params_message(missing_params)
    if missing_params.one?
      "The tool could not run because #{missing_params.first} is missing"
    else
      "The tool could not run because these parameters are missing: #{missing_params.join(', ')}"
    end
  end

  def build_prompt_context_for_templates(state)
    prompt_context = state[:prompt_context] || {}
    fallback_prompt_context = {
      conversation: state[:conversation],
      contact: state[:contact]
    }.compact

    source_context = state.key?(:prompt_context) ? prompt_context : fallback_prompt_context
    source_context.deep_stringify_keys
  end

  def assistant_template_context
    {
      'id' => @assistant.id,
      'name' => @assistant.name,
      'description' => @assistant.description,
      'product_name' => @assistant.config['product_name']
    }
  end

  def account_template_context
    {
      'id' => @assistant.account_id,
      'name' => @assistant.account.name,
      'locale' => @assistant.account.locale
    }
  end

  def execute_http_request(url, body, tool_context)
    uri = URI.parse(url)

    # Check if resolved IP is private
    check_private_ip!(uri.host)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    http.open_timeout = 10
    http.max_retries = 0 # Disable redirects

    request = build_http_request(uri, body)
    apply_authentication(request)
    apply_metadata_headers(request, tool_context)

    response = http.request(request)

    raise "HTTP request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    validate_response!(response)

    response
  end

  def check_private_ip!(hostname)
    ip_address = IPAddr.new(Resolv.getaddress(hostname))

    raise 'Request blocked: hostname resolves to private IP address' if PRIVATE_IP_RANGES.any? { |range| range.include?(ip_address) }
  rescue Resolv::ResolvError, SocketError => e
    raise "DNS resolution failed: #{e.message}"
  end

  def validate_response!(response)
    content_length = response['content-length']&.to_i
    if content_length && content_length > MAX_RESPONSE_SIZE
      raise "Response size #{content_length} bytes exceeds maximum allowed #{MAX_RESPONSE_SIZE} bytes"
    end

    return unless response.body && response.body.bytesize > MAX_RESPONSE_SIZE

    raise "Response body size #{response.body.bytesize} bytes exceeds maximum allowed #{MAX_RESPONSE_SIZE} bytes"
  end

  def build_http_request(uri, body)
    method = @custom_tool.http_method
    raise ToolConfigurationError, "unsupported HTTP method #{method}" unless Captain::CustomTool::HTTP_METHODS.include?(method)

    request = Net::HTTPGenericRequest.new(
      method,
      Captain::CustomTool::REQUEST_BODY_HTTP_METHODS.include?(method),
      method != 'HEAD',
      uri.request_uri
    )

    if body.present? && request.request_body_permitted?
      request.body = body
      request['Content-Type'] = 'application/json'
    end

    request
  end

  def apply_authentication(request)
    headers = @custom_tool.build_auth_headers
    headers.each { |key, value| request[key] = value }

    credentials = @custom_tool.build_basic_auth_credentials
    request.basic_auth(*credentials) if credentials
  end

  def apply_metadata_headers(request, tool_context)
    state = tool_context&.state || {}
    metadata_headers = @custom_tool.build_metadata_headers(state)
    metadata_headers.each { |key, value| request[key] = value }
  end
end
