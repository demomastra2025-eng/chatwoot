class Captain::Tools::HttpRequestExecutor
  class MissingRequiredParametersError < StandardError; end
  class ToolConfigurationError < StandardError; end

  class HttpRequestFailedError < StandardError
    attr_reader :status

    def initialize(status)
      @status = status.to_i
      super("HTTP request failed with status #{@status}")
    end
  end

  PRIVATE_IP_RANGES = [
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('::1'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10')
  ].freeze
  MAX_RESPONSE_SIZE = 1.megabyte
  RETRYABLE_HTTP_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze

  def initialize(assistant:, custom_tool:, state: {}, feature: nil, preferences: nil, enforce_safety: false)
    @assistant = assistant
    @custom_tool = custom_tool
    @state = state || {}
    @feature = feature
    @preferences = preferences
    @enforce_safety = enforce_safety
  end

  def call(params = {})
    request_preview = build_request_preview(params)
    execution_url = request_preview.delete(:execution_url)
    response = execute_http_request(execution_url, request_preview[:body])
    formatted_body = @custom_tool.format_response(response.body)
    response_with_artifacts(response.body, formatted_body)
  rescue MissingRequiredParametersError => e
    Rails.logger.warn("HttpTool missing parameters for #{@custom_tool.slug}: #{e.message}")
    Captain::ToolResult.failure_output(error: e.message, audit: failure_audit(request_preview, failure_stage: 'validation'))
  rescue ToolConfigurationError => e
    Rails.logger.error("HttpTool configuration error for #{@custom_tool.slug}: #{e.message}")
    Captain::ToolResult.failure_output(
      error: 'The tool could not run because it is misconfigured',
      audit: failure_audit(request_preview, failure_stage: 'configuration', exception_class: e.class.name)
    )
  rescue HttpRequestFailedError => e
    Rails.logger.error("HttpTool HTTP error for #{@custom_tool.slug}: #{e.message}")
    Captain::ToolResult.failure_output(
      error: e.message,
      retryable: retryable_http_status?(e.status),
      audit: failure_audit(request_preview, failure_stage: 'http', http_status: e.status)
    )
  rescue StandardError => e
    Rails.logger.error("HttpTool execution error for #{@custom_tool.slug}: #{e.class} - #{e.message}")
    Captain::ToolResult.failure_output(
      error: 'An error occurred while executing the request',
      retryable: retryable_exception?(e),
      audit: failure_audit(request_preview, failure_stage: 'runtime', exception_class: e.class.name)
    )
  end

  def preview(params = {})
    build_request_preview(params).except(:execution_url)
  end

  def execute_with_details(params = {}, raise_on_http_error: false)
    request_preview = build_request_preview(params)
    execution_url = request_preview.delete(:execution_url)
    argument_error = preview_safety_error_for(:tool_arguments, request_preview[:resolved_params])
    return blocked_details_response(request_preview, argument_error) if argument_error

    response = execute_http_request(
      execution_url,
      request_preview[:body],
      raise_on_http_error: raise_on_http_error
    )
    formatted_body, format_error = format_response_details(response.body)
    if format_error
      return {
        preview: request_preview,
        tool_result: Captain::ToolResult.failure(
          error: format_error,
          retryable: false,
          audit: failure_audit(
            request_preview,
            failure_stage: 'response_template',
            http_status: response.code.to_i
          )
        ),
        response: build_response_details(
          response,
          formatted_body: nil,
          format_error: format_error,
          successful: false
        )
      }
    end

    result_error = preview_safety_error_for(:tool_results, formatted_body)
    return blocked_details_response(request_preview, result_error, response: response) if result_error

    tool_result = Captain::ToolResult.normalize(
      formatted_body,
      audit: success_audit(request_preview, response)
    )

    {
      preview: request_preview,
      tool_result: tool_result,
      response: build_response_details(response, formatted_body: formatted_body)
    }
  end

  private

  def format_response_details(raw_response_body)
    [@custom_tool.format_response(raw_response_body), nil]
  rescue StandardError => e
    [nil, e.message]
  end

  def build_request_preview(params)
    request_params = resolve_request_params(params, @state)
    template_context = build_template_context(request_params, @state)
    execution_url = @custom_tool.build_request_url(
      request_params,
      template_context: template_context
    )

    {
      resolved_params: request_params,
      url: masked_preview_url(execution_url),
      execution_url: execution_url,
      body: @custom_tool.build_request_body(request_params, template_context: template_context)
    }
  end

  def build_template_context(params, state)
    stringified_params = params.deep_stringify_keys
    prompt_context = build_prompt_context_for_templates(state)
    safe_root_params = stringified_params.except(*Captain::CustomTool::RESERVED_TEMPLATE_PARAM_NAMES)

    {
      'params' => stringified_params,
      'p' => stringified_params,
      'contact' => prompt_context['contact'] || {},
      'conversation' => prompt_context['conversation'] || {},
      'deal' => prompt_context['deal'] || {},
      'task' => prompt_context['task'] || {},
      'appointment' => prompt_context['appointment'] || {},
      'assistant' => assistant_template_context,
      'account' => account_template_context,
      'visible_fields' => prompt_context['visible_fields'] || {}
    }.merge(safe_root_params)
  end

  def masked_preview_url(url)
    return url unless @custom_tool.auth_type == 'api_key'
    return url unless @custom_tool.auth_config['location'] == 'query'

    api_key_name = @custom_tool.auth_config['name'].to_s
    return url if api_key_name.blank?

    uri = URI.parse(url)
    query_pairs = URI.decode_www_form(uri.query.to_s)
    return url unless query_pairs.any? { |key, _value| key == api_key_name }

    uri.query = URI.encode_www_form(
      query_pairs.map do |key, value|
        key == api_key_name ? [key, 'REDACTED'] : [key, value]
      end
    )
    uri.to_s
  rescue URI::InvalidURIError
    url
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
      contact: state[:contact],
      deal: state[:deal],
      task: state[:task],
      appointment: state[:appointment]
    }.compact

    source_context = state.key?(:prompt_context) ? prompt_context : fallback_prompt_context
    source_context.deep_stringify_keys
  end

  def assistant_template_context
    {
      'id' => @assistant.id,
      'name' => @assistant.name,
      'description' => @assistant.description
    }
  end

  def account_template_context
    {
      'id' => @assistant.account_id,
      'name' => @assistant.account.name,
      'locale' => @assistant.account.locale
    }
  end

  def execute_http_request(url, body, raise_on_http_error: true)
    uri = URI.parse(url)
    resolved_ip = resolve_public_ip!(uri.host)

    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = resolved_ip
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    http.open_timeout = 10
    http.max_retries = 0

    request = build_http_request(uri, body)
    apply_authentication(request)
    apply_metadata_headers(request)

    response = http.request(request)
    validate_response!(response)
    raise HttpRequestFailedError, response.code if raise_on_http_error && !response.is_a?(Net::HTTPSuccess)

    response
  end

  def resolve_public_ip!(hostname)
    addresses = Resolv.getaddresses(hostname).uniq
    raise 'DNS resolution failed: no addresses returned' if addresses.empty?

    ip_addresses = addresses.map { |address| IPAddr.new(address) }
    raise 'Request blocked: hostname resolves to private IP address' if ip_addresses.any? { |address| private_ip?(address) }

    addresses.first
  rescue Resolv::ResolvError, SocketError => e
    raise "DNS resolution failed: #{e.message}"
  end

  def private_ip?(ip_address)
    PRIVATE_IP_RANGES.any? { |range| range.include?(ip_address) }
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

  def apply_metadata_headers(request)
    metadata_headers = @custom_tool.build_metadata_headers(@state)
    metadata_headers.each { |key, value| request[key] = value }
  end

  def normalize_response_headers(headers)
    headers.to_h.transform_values do |value|
      value.is_a?(Array) && value.one? ? value.first : value
    end
  end

  def response_with_artifacts(raw_response_body, formatted_body)
    return formatted_body unless @custom_tool.allow_file_artifacts?

    artifact_candidates = Captain::Tools::HttpArtifactExtractor.call(
      raw_response_body: raw_response_body,
      formatted_response: formatted_body,
      assistant: @assistant,
      custom_tool: @custom_tool
    )
    return formatted_body if artifact_candidates.blank?

    {
      content: redacted_artifact_content(formatted_body, artifact_candidates),
      artifact_candidates: artifact_candidates
    }.to_json
  end

  def redacted_artifact_content(content, artifact_candidates)
    artifact_candidates.each_with_index.reduce(content.to_s.dup) do |redacted_content, (candidate, index)|
      payload = Captain::Tools::HttpArtifactToken.decode(candidate[:id] || candidate['id'])
      redacted_content.gsub(payload[:url].to_s, "[artifact_candidate:#{index + 1}]")
    rescue Captain::Tools::HttpArtifactToken::InvalidToken
      redacted_content
    end
  end

  def build_response_details(response, formatted_body:, format_error: nil, successful: nil)
    successful = response.is_a?(Net::HTTPSuccess) if successful.nil?

    {
      successful: successful,
      status: response.code.to_i,
      body: response.body,
      formatted_body: formatted_body,
      format_error: format_error,
      headers: normalize_response_headers(response.to_hash)
    }.compact
  end

  def preview_safety_error_for(stage, content)
    return unless @enforce_safety
    return if @feature.blank?

    case stage
    when :tool_arguments
      Captain::ToolSafety.check_arguments!(
        feature: @feature,
        arguments: content,
        account: @assistant.account,
        preferences: @preferences
      )
    when :tool_results
      Captain::ToolSafety.check_result!(
        feature: @feature,
        result: content,
        account: @assistant.account,
        preferences: @preferences
      )
    end

    nil
  rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
    e
  end

  def blocked_details_response(request_preview, error, response: nil)
    blocked_message = Captain::ToolSafety.blocked_message(stage: error.stage, error: error)

    {
      preview: request_preview,
      tool_result: Captain::ToolResult.failure(
        error: blocked_message,
        retryable: false,
        audit: failure_audit(
          request_preview,
          failure_stage: error.stage,
          failure_reason: error.reason,
          http_status: response&.code&.to_i
        )
      ),
      response: {
        successful: false,
        blocked: true,
        stage: error.stage,
        reason: error.reason,
        status: response&.code&.to_i,
        body: nil,
        formatted_body: blocked_message,
        headers: response ? normalize_response_headers(response.to_hash) : {}
      }.compact
    }
  end

  def success_audit(request_preview, response)
    {
      custom_tool_slug: @custom_tool.slug,
      http_method: @custom_tool.http_method,
      endpoint_host: URI.parse(request_preview[:url]).host,
      http_status: response.code.to_i
    }
  rescue StandardError
    {
      custom_tool_slug: @custom_tool.slug,
      http_method: @custom_tool.http_method,
      http_status: response&.code&.to_i
    }.compact
  end

  def failure_audit(request_preview, failure_stage:, exception_class: nil, failure_reason: nil, http_status: nil)
    {
      custom_tool_slug: @custom_tool.slug,
      http_method: @custom_tool.http_method,
      endpoint_host: request_preview.present? ? URI.parse(request_preview[:url]).host : nil,
      failure_stage: failure_stage,
      failure_reason: failure_reason,
      exception_class: exception_class,
      http_status: http_status
    }.compact
  rescue StandardError
    {
      custom_tool_slug: @custom_tool.slug,
      http_method: @custom_tool.http_method,
      failure_stage: failure_stage,
      failure_reason: failure_reason,
      exception_class: exception_class,
      http_status: http_status
    }.compact
  end

  def retryable_http_status?(status)
    RETRYABLE_HTTP_STATUSES.include?(status.to_i)
  end

  def retryable_exception?(error)
    [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Timeout::Error,
      Errno::ECONNRESET,
      EOFError
    ].any? { |klass| error.is_a?(klass) }
  end
end
