require 'digest'
require 'timeout'

class Captain::Tools::HttpRequestExecutor
  class MissingRequiredParametersError < StandardError; end
  class ToolConfigurationError < StandardError; end

  class HttpRequestFailedError < StandardError
    MAX_ERROR_BODY_LENGTH = 500
    SAFE_ERROR_DETAIL_KEYS = %w[code detail error message reason title].freeze
    SENSITIVE_KEY_PATTERN = /(api[_-]?key|authorization|email|name|password|phone|secret|token)/i
    SENSITIVE_VALUE_PATTERNS = [
      [/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, '[REDACTED_EMAIL]'],
      [/\+?\d[\d\s\-()]*\*+[\d\s\-()*]*\d/, '[REDACTED_PHONE]'],
      [/(?<!\d)\+?\d[\d\s\-()]{6,}\d(?!\d)/, '[REDACTED_PHONE]'],
      [/(bearer|token|secret|password|api[_-]?key)\s*[:=]\s*\S+/i, '\\1=[REDACTED]']
    ].freeze

    attr_reader :status

    def initialize(status, body: nil)
      @status = status.to_i
      super(error_message(body))
    end

    private

    def error_message(body)
      message = "HTTP request failed with status #{@status}"
      details = response_body_details(body)
      return message if details.blank? || @status >= 500

      "#{message}: #{details}"
    end

    def response_body_details(body)
      parsed_body = parse_json_body(body)
      return unless parsed_body.is_a?(Hash)

      sanitized_body = sanitize_error_hash(parsed_body)
      return if sanitized_body.blank?

      JSON.generate(Captain::EncodingNormalizer.utf8(sanitized_body)).squish.first(MAX_ERROR_BODY_LENGTH).presence
    end

    def parse_json_body(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError, TypeError
      nil
    end

    def sanitize_error_details(value)
      case value
      when Hash
        sanitize_error_hash(value)
      when Array
        value.filter_map { |item| sanitize_error_details(item) }
      when String
        redact_sensitive_value(value)
      else
        value
      end
    end

    def sanitize_error_hash(value)
      value.each_with_object({}) do |(key, item), memo|
        key = key.to_s
        next if sensitive_error_key?(key)
        next unless safe_error_detail_key?(key)

        sanitized_item = sanitize_error_details(item)
        memo[key] = sanitized_item if sanitized_item.present?
      end
    end

    def safe_error_detail_key?(key)
      SAFE_ERROR_DETAIL_KEYS.include?(key.to_s)
    end

    def sensitive_error_key?(key)
      key.to_s.match?(SENSITIVE_KEY_PATTERN)
    end

    def redact_sensitive_value(value)
      SENSITIVE_VALUE_PATTERNS.reduce(value.to_s) do |text, (pattern, replacement)|
        text.gsub(pattern, replacement)
      end
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
  MAX_AGGREGATE_ITEMS = 10_000
  MAX_BATCH_ITEMS = 500
  MAX_FLOW_REQUESTS = 25
  MAX_FLOW_DURATION_SECONDS = 120
  RETRYABLE_HTTP_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze
  AUTO_RETRYABLE_HTTP_STATUSES = [502, 503, 504].freeze
  AUTO_RETRYABLE_HTTP_METHODS = %w[GET HEAD].freeze
  AUTO_RETRYABLE_CUSTOM_TOOL_SLUGS = %w[custom_search_apartments].freeze
  MAX_HTTP_ATTEMPTS = 2
  RETRY_BACKOFF_SECONDS = 0.25
  REDIRECT_HTTP_STATUSES = [301, 302, 303, 307, 308].freeze
  METHOD_PRESERVING_REDIRECT_STATUSES = [307, 308].freeze

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
    execution_headers = request_preview.delete(:execution_headers)
    execution_body = request_preview.delete(:execution_body)
    execution_params = request_preview.delete(:execution_params)
    execution = execute_request_flow(execution_url, execution_body, execution_headers, execution_params)
    raw_response_body = normalize_response_body(execution[:body])
    formatted_body = @custom_tool.format_response(raw_response_body)
    response_with_artifacts(raw_response_body, formatted_body)
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
    build_request_preview(params).except(:execution_url, :execution_headers, :execution_body, :execution_params)
  end

  def execute_with_details(params = {}, raise_on_http_error: false)
    request_preview = build_request_preview(params)
    execution_url = request_preview.delete(:execution_url)
    execution_headers = request_preview.delete(:execution_headers)
    execution_body = request_preview.delete(:execution_body)
    execution_params = request_preview.delete(:execution_params)
    argument_error = preview_safety_error_for(:tool_arguments, execution_params)
    return blocked_details_response(request_preview, argument_error) if argument_error

    execution = execute_request_flow(
      execution_url,
      execution_body,
      execution_headers,
      execution_params,
      raise_on_http_error: raise_on_http_error
    )
    response = execution[:response]
    raw_response_body = normalize_response_body(execution[:body])
    formatted_body, format_error = format_response_details(raw_response_body)
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
          successful: false,
          raw_response_body: raw_response_body
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
      response: build_response_details(response, formatted_body: formatted_body, raw_response_body: raw_response_body)
    }
  end

  private

  def format_response_details(raw_response_body)
    [@custom_tool.format_response(raw_response_body), nil]
  rescue StandardError => e
    [nil, e.message]
  end

  def normalize_response_body(body)
    Captain::EncodingNormalizer.string(body.to_s)
  end

  def build_request_preview(params)
    request_params = resolve_request_params(params, @state)
    template_context = build_template_context(request_params, @state)
    masked_params = masked_preview_params(request_params)
    masked_body_params = masked_preview_params(request_params, preserve_types: true)
    masked_template_context = build_template_context(masked_params, @state)
    masked_body_template_context = build_template_context(masked_body_params, @state)
    execution_url = @custom_tool.build_request_url(
      request_params,
      template_context: template_context
    )
    preview_url = @custom_tool.build_request_url(
      masked_params,
      template_context: masked_template_context
    )
    execution_body = @custom_tool.build_request_body(request_params, template_context: template_context)
    execution_headers = @custom_tool.build_request_headers(request_params)

    preview = {
      resolved_params: masked_params,
      url: masked_preview_url(preview_url),
      execution_url: execution_url,
      execution_headers: execution_headers,
      execution_body: execution_body,
      execution_params: request_params,
      body: @custom_tool.build_request_body(masked_body_params, template_context: masked_body_template_context)
    }
    preview[:headers] = masked_preview_headers(execution_headers) if execution_headers.present?
    preview
  end

  def masked_preview_headers(headers)
    headers.transform_values { 'REDACTED' }
  end

  def masked_preview_params(params, preserve_types: false)
    masked_param_definitions = @custom_tool.parameter_definitions.select do |definition|
      [
        Captain::CustomTool::PARAM_REQUEST_LOCATION_QUERY,
        Captain::CustomTool::PARAM_REQUEST_LOCATION_HEADER
      ].include?(definition['request_location'])
    end

    params.deep_dup.tap do |masked_params|
      masked_param_definitions.each do |definition|
        name = definition['name']
        masked_value = preserve_types ? masked_value_for_type(definition['type']) : 'REDACTED'
        masked_params[name] = masked_value if masked_params.key?(name)
        masked_params[name.to_sym] = masked_value if masked_params.key?(name.to_sym)
      end
    end
  end

  def masked_value_for_type(type)
    {
      'number' => 0,
      'boolean' => false,
      'array' => [],
      'object' => {}
    }.fetch(type, 'REDACTED')
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
      'communication_thread' => prompt_context['communication_thread'] || {},
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
      communication_thread: state[:communication_thread],
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

  def execute_request_flow(url, body, headers, execution_params, raise_on_http_error: true)
    @request_count = 0
    @logical_request_count = 0
    @aggregate_item_count = 0
    @aggregate_bytes = 2 # Empty JSON array: []
    @flow_deadline = monotonic_time + MAX_FLOW_DURATION_SECONDS

    if batching_enabled?
      execute_batched_flow(execution_params, raise_on_http_error: raise_on_http_error)
    elsif pagination_enabled?
      execute_paginated_flow(url, body, headers, raise_on_http_error: raise_on_http_error)
    else
      response = execute_flow_request(url, body, headers, raise_on_http_error: raise_on_http_error)
      flow_result(response, response.body)
    end
  ensure
    @flow_deadline = nil
  end

  def execute_batched_flow(execution_params, raise_on_http_error:)
    options = http_options['batching']
    parameter_name = options['items_parameter']
    items = execution_params[parameter_name]
    unless items.is_a?(Array) && items.present?
      raise MissingRequiredParametersError, "The tool could not run because #{parameter_name} must be a non-empty array"
    end
    if items.size > MAX_BATCH_ITEMS
      raise MissingRequiredParametersError, "The tool could not run because #{parameter_name} exceeds #{MAX_BATCH_ITEMS} items"
    end

    batches = items.each_slice(options['batch_size']).to_a
    raise ToolConfigurationError, "batching exceeds #{MAX_FLOW_REQUESTS} requests" if batches.size > MAX_FLOW_REQUESTS

    payloads = []
    last_response = nil
    batches.each_with_index do |batch, index|
      request_params = execution_params.merge(parameter_name => batch)
      url, body, headers = build_execution_request(request_params)
      last_response = execute_flow_request(url, body, headers, raise_on_http_error: raise_on_http_error)
      return flow_result(last_response, last_response.body) unless successful_response?(last_response)

      append_aggregate_payloads!(payloads, [parse_flow_json(last_response.body)])
      wait_between_flow_requests(options['interval_ms']) if index < batches.size - 1
    end

    flow_result(last_response, serialize_flow_payload(payloads))
  end

  def execute_paginated_flow(url, body, headers, raise_on_http_error:)
    options = http_options['pagination']
    origin = request_origin(url)
    current_url = paginated_url(url, options, options['start_page'])
    visited_urls = Set.new
    payloads = []
    last_response = nil

    options['max_pages'].times do |page_index|
      raise ToolConfigurationError, 'pagination produced a repeated URL' unless visited_urls.add?(current_url)

      last_response = execute_flow_request(current_url, body, headers, raise_on_http_error: raise_on_http_error)
      return flow_result(last_response, last_response.body) unless successful_response?(last_response)

      payload = parse_flow_json(last_response.body)
      page_items = pagination_items(payload, options['items_path'])
      break if page_items.respond_to?(:empty?) && page_items.empty?

      append_page_payload(payloads, payload, page_items, options['items_path'])
      next_url = next_pagination_url(current_url, payload, options, page_index)
      break if next_url.blank?

      current_url = validate_follow_up_url!(next_url, origin)
      wait_between_flow_requests(options['interval_ms'])
    end

    flow_result(last_response, serialize_flow_payload(payloads))
  end

  def execute_flow_request(url, body, headers, raise_on_http_error:)
    @logical_request_count += 1
    execute_http_request(
      url,
      body,
      headers,
      logical_request_index: @logical_request_count,
      raise_on_http_error: raise_on_http_error
    )
  end

  def build_execution_request(request_params)
    template_context = build_template_context(request_params, @state)
    [
      @custom_tool.build_request_url(request_params, template_context: template_context),
      @custom_tool.build_request_body(request_params, template_context: template_context),
      @custom_tool.build_request_headers(request_params)
    ]
  end

  def paginated_url(url, options, page_number)
    return url unless options['mode'] == 'page_parameter'

    with_query_parameter(url, options['parameter_name'], page_number)
  end

  def next_pagination_url(current_url, payload, options, page_index)
    if options['mode'] == 'next_url'
      extract_json_path!(payload, options['next_url_path'], 'pagination.next_url_path').presence
    elsif page_index + 1 < options['max_pages']
      paginated_url(current_url, options, options['start_page'] + page_index + 1)
    end
  end

  def pagination_items(payload, items_path)
    return extract_json_path!(payload, items_path, 'pagination.items_path') if items_path.present?

    payload
  end

  def append_page_payload(payloads, payload, page_items, items_path)
    if items_path.present? || page_items.is_a?(Array)
      raise ToolConfigurationError, 'pagination items path must resolve to an array' unless page_items.is_a?(Array)

      append_aggregate_payloads!(payloads, page_items)
    else
      append_aggregate_payloads!(payloads, [payload])
    end
  end

  def append_aggregate_payloads!(payloads, additions)
    projected_items = @aggregate_item_count + additions.size
    if projected_items > MAX_AGGREGATE_ITEMS
      raise ToolConfigurationError,
            "aggregated response exceeds #{MAX_AGGREGATE_ITEMS} items"
    end

    encoded_additions = JSON.generate(Captain::EncodingNormalizer.utf8(additions))
    projected_bytes = payloads.empty? ? encoded_additions.bytesize : @aggregate_bytes + encoded_additions.bytesize - 1
    raise ToolConfigurationError, 'aggregated response exceeds the maximum allowed size' if projected_bytes > MAX_RESPONSE_SIZE

    @aggregate_item_count = projected_items
    @aggregate_bytes = projected_bytes
    payloads.concat(additions)
  end

  def extract_json_path!(payload, path, field_name)
    path.to_s.split('.').reduce(payload) do |value, key|
      raise ToolConfigurationError, "#{field_name} does not exist in the response" unless value.is_a?(Hash) && value.key?(key)

      value[key]
    end
  end

  def parse_flow_json(body)
    JSON.parse(normalize_response_body(body))
  rescue JSON::ParserError
    raise ToolConfigurationError, 'batching and pagination require JSON responses'
  end

  def serialize_flow_payload(payload)
    body = JSON.generate(Captain::EncodingNormalizer.utf8(payload))
    raise ToolConfigurationError, 'aggregated response exceeds the maximum allowed size' if body.bytesize > MAX_RESPONSE_SIZE

    body
  end

  def flow_result(response, body)
    { response: response, body: body, request_count: @request_count }
  end

  def with_query_parameter(url, key, value)
    uri = URI.parse(url)
    pairs = URI.decode_www_form(uri.query.to_s).reject { |pair_key, _pair_value| pair_key == key }
    pairs << [key, value.to_s]
    uri.query = URI.encode_www_form(pairs)
    uri.to_s
  end

  def validate_follow_up_url!(url, expected_origin)
    uri = URI.parse(url.to_s)
    raise ToolConfigurationError, 'pagination next URL must be absolute' unless uri.absolute?
    raise ToolConfigurationError, 'pagination next URL must use the same origin' unless request_origin(uri.to_s) == expected_origin
    raise ToolConfigurationError, 'pagination next URL must not contain user credentials' if uri.userinfo.present?

    uri.to_s
  rescue URI::InvalidURIError
    raise ToolConfigurationError, 'pagination returned an invalid next URL'
  end

  def request_origin(url)
    uri = URI.parse(url)
    raise ToolConfigurationError, 'HTTP flow URL must use HTTP or HTTPS' unless %w[http https].include?(uri.scheme)

    [uri.scheme, uri.host, uri.port]
  rescue URI::InvalidURIError
    raise ToolConfigurationError, 'HTTP flow URL is invalid'
  end

  def wait_between_flow_requests(interval_ms)
    delay = interval_ms.to_f / 1000
    return unless delay.positive?

    raise Timeout::Error, 'HTTP tool flow exceeded its runtime limit' if flow_time_remaining <= delay

    sleep(delay)
  end

  def batching_enabled?
    http_options.dig('batching', 'enabled')
  end

  def pagination_enabled?
    http_options.dig('pagination', 'enabled')
  end

  def http_options
    @http_options ||= @custom_tool.effective_http_options
  end

  def execute_http_request(url, body, headers = {}, logical_request_index: 1, raise_on_http_error: true)
    uri = URI.parse(url)
    attempts = http_request_attempts
    idempotency_key = build_idempotency_key(uri, body, logical_request_index)

    attempts.times do |attempt_index|
      response = perform_http_request_with_redirects(uri, body, headers, idempotency_key)

      if retryable_response_for_request?(response) && retry_remaining?(attempt_index, attempts)
        log_retry_attempt(response.code.to_i, attempt_index + 1, attempts)
        wait_before_retry
        next
      end

      raise HttpRequestFailedError.new(response.code, body: response.body) if raise_on_http_error && !successful_response?(response)

      return response
    rescue StandardError => e
      if retryable_exception?(e) && network_retry_allowed? && retry_remaining?(attempt_index, attempts)
        log_retry_attempt(e.class.name, attempt_index + 1, attempts)
        wait_before_retry
        next
      end

      raise
    end
  end

  def perform_http_request_with_redirects(initial_uri, body, headers, idempotency_key)
    uri = initial_uri
    origin = request_origin(initial_uri.to_s)
    redirect_count = 0

    loop do
      enforce_flow_deadline!
      resolved_ip = resolve_public_ip!(uri.host)
      response = perform_http_request(uri, resolved_ip, body, headers, idempotency_key)
      return response unless REDIRECT_HTTP_STATUSES.include?(response.code.to_i)
      return response unless http_options.dig('redirects', 'enabled')

      max_redirects = http_options.dig('redirects', 'max_redirects')
      raise ToolConfigurationError, "redirect limit of #{max_redirects} exceeded" if redirect_count >= max_redirects

      uri = redirect_uri!(uri, response, origin)
      redirect_count += 1
    end
  end

  def redirect_uri!(current_uri, response, expected_origin)
    location = response['location'].to_s
    raise ToolConfigurationError, 'redirect response is missing a Location header' if location.blank?
    if Captain::CustomTool::REQUEST_BODY_HTTP_METHODS.include?(@custom_tool.http_method) &&
       METHOD_PRESERVING_REDIRECT_STATUSES.exclude?(response.code.to_i)
      raise ToolConfigurationError, 'mutating requests may only follow 307 or 308 redirects'
    end

    target_uri = URI.join(current_uri.to_s, location)
    raise ToolConfigurationError, 'redirect URL must use the same origin' unless request_origin(target_uri.to_s) == expected_origin
    raise ToolConfigurationError, 'redirect URL must not contain user credentials' if target_uri.userinfo.present?

    target_uri
  rescue URI::InvalidURIError
    raise ToolConfigurationError, 'redirect response contains an invalid Location URL'
  end

  def perform_http_request(uri, resolved_ip, body, headers, idempotency_key)
    consume_network_request!
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = resolved_ip
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = bounded_request_timeout(http_options.dig('timeout', 'read_seconds'))
    http.open_timeout = bounded_request_timeout(http_options.dig('timeout', 'open_seconds'))
    http.max_retries = 0

    request = build_http_request(uri, body)
    apply_custom_headers(request, headers)
    apply_request_content_type(request, body)
    apply_authentication(request)
    apply_metadata_headers(request)
    apply_idempotency_header(request, idempotency_key)

    with_flow_deadline do
      http.request(request) { |response| stream_response_body!(response) }
    end
  end

  def consume_network_request!
    raise ToolConfigurationError, "HTTP flow exceeds #{MAX_FLOW_REQUESTS} requests" if @request_count >= MAX_FLOW_REQUESTS

    enforce_flow_deadline!
    @request_count += 1
  end

  def stream_response_body!(response)
    validate_response_content_length!(response)
    body = ''.b

    response.read_body do |chunk|
      enforce_flow_deadline!
      projected_size = body.bytesize + chunk.bytesize
      raise "Response body size exceeds maximum allowed #{MAX_RESPONSE_SIZE} bytes" if projected_size > MAX_RESPONSE_SIZE

      body << chunk
    end
    response.body = body
  end

  def validate_response_content_length!(response)
    content_length = response['content-length']&.to_i
    return unless content_length && content_length > MAX_RESPONSE_SIZE

    raise "Response size #{content_length} bytes exceeds maximum allowed #{MAX_RESPONSE_SIZE} bytes"
  end

  def with_flow_deadline(&)
    remaining = flow_time_remaining
    raise Timeout::Error, 'HTTP tool flow exceeded its runtime limit' unless remaining.positive?

    Timeout.timeout(remaining, Timeout::Error, 'HTTP tool flow exceeded its runtime limit', &)
  end

  def enforce_flow_deadline!
    raise Timeout::Error, 'HTTP tool flow exceeded its runtime limit' unless flow_time_remaining.positive?
  end

  def bounded_request_timeout(configured_timeout)
    return configured_timeout unless @flow_deadline

    remaining = flow_time_remaining
    raise Timeout::Error, 'HTTP tool flow exceeded its runtime limit' unless remaining.positive?

    [configured_timeout.to_f, remaining].min
  end

  def flow_time_remaining
    return Float::INFINITY unless @flow_deadline

    @flow_deadline - monotonic_time
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

  def build_http_request(uri, body)
    method = @custom_tool.http_method
    raise ToolConfigurationError, "unsupported HTTP method #{method}" unless Captain::CustomTool::HTTP_METHODS.include?(method)

    request = Net::HTTPGenericRequest.new(
      method,
      Captain::CustomTool::REQUEST_BODY_HTTP_METHODS.include?(method),
      method != 'HEAD',
      uri.request_uri
    )

    request.body = body if body.present? && request.request_body_permitted?

    request
  end

  def apply_request_content_type(request, body)
    return unless body.present? && request.request_body_permitted?

    request['Content-Type'] = @custom_tool.request_content_type
  end

  def apply_authentication(request)
    headers = @custom_tool.build_auth_headers
    headers.each { |key, value| request[key] = value }

    credentials = @custom_tool.build_basic_auth_credentials
    request.basic_auth(*credentials) if credentials
  end

  def apply_custom_headers(request, headers)
    headers.each { |key, value| request[key] = value }
  end

  def apply_metadata_headers(request)
    metadata_headers = @custom_tool.build_metadata_headers(@state)
    metadata_headers.each { |key, value| request[key] = value }
  end

  def apply_idempotency_header(request, idempotency_key)
    request['Idempotency-Key'] = idempotency_key if idempotency_key
  end

  def build_idempotency_key(uri, body, logical_request_index)
    return unless http_options.dig('idempotency', 'enabled')

    seed = [idempotency_anchor, @custom_tool.slug, @custom_tool.http_method, logical_request_index, uri.to_s, body.to_s].join("\0")
    "onelink-#{Digest::SHA256.hexdigest(seed).first(48)}"
  end

  def idempotency_anchor
    @idempotency_anchor ||= @state[:request_id].presence || @state['request_id'].presence || current_event_request_id || SecureRandom.uuid
  end

  def current_event_request_id
    Llm::EventBus.request_id if Llm::EventBus.respond_to?(:request_id)
  rescue StandardError
    nil
  end

  def normalize_response_headers(headers)
    headers.to_h.transform_values do |value|
      value.is_a?(Array) && value.one? ? value.first : value
    end
  end

  def response_with_artifacts(raw_response_body, formatted_body)
    formatted_body = Captain::EncodingNormalizer.string(formatted_body.to_s)
    return formatted_body unless @custom_tool.allow_file_artifacts?

    artifact_candidates = Captain::Tools::HttpArtifactExtractor.call(
      raw_response_body: raw_response_body,
      formatted_response: formatted_body,
      assistant: @assistant,
      custom_tool: @custom_tool
    )
    return formatted_body if artifact_candidates.blank?

    Captain::ToolResult.render(
      Captain::ToolResult.success(
        data: {
          content: redacted_artifact_content(formatted_body, artifact_candidates),
          artifact_candidates: artifact_candidates
        }
      )
    )
  end

  def redacted_artifact_content(content, artifact_candidates)
    artifact_candidates.each_with_index.reduce(content.to_s.dup) do |redacted_content, (candidate, index)|
      payload = Captain::Tools::HttpArtifactToken.decode(candidate[:id] || candidate['id'])
      redacted_content.gsub(payload[:url].to_s, "[artifact_candidate:#{index + 1}]")
    rescue Captain::Tools::HttpArtifactToken::InvalidToken
      redacted_content
    end
  end

  def build_response_details(response, formatted_body:, format_error: nil, successful: nil, raw_response_body: nil)
    successful = successful_response?(response) if successful.nil?

    {
      successful: successful,
      status: response.code.to_i,
      body: raw_response_body || normalize_response_body(response.body),
      formatted_body: Captain::EncodingNormalizer.utf8(formatted_body),
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

  def successful_response?(response)
    response.is_a?(Net::HTTPSuccess)
  end

  def http_request_attempts
    return http_options.dig('retry', 'max_attempts') if configured_retry_enabled?
    return MAX_HTTP_ATTEMPTS if legacy_auto_retryable_request?

    1
  end

  def retryable_response_for_request?(response)
    statuses = if configured_retry_enabled?
                 http_options.dig('retry', 'statuses')
               else
                 AUTO_RETRYABLE_HTTP_STATUSES
               end

    statuses.include?(response.code.to_i) && (configured_retry_enabled? || legacy_auto_retryable_request?)
  end

  def configured_retry_enabled?
    http_options.dig('retry', 'enabled')
  end

  def legacy_auto_retryable_request?
    idempotent_retryable_http_method? || allowlisted_retryable_post_tool?
  end

  def network_retry_allowed?
    return true if idempotent_retryable_http_method?

    configured_retry_enabled? && http_options.dig('idempotency', 'enabled')
  end

  def retry_backoff_seconds
    return RETRY_BACKOFF_SECONDS unless configured_retry_enabled?

    http_options.dig('retry', 'backoff_ms').to_f / 1000
  end

  def wait_before_retry
    delay = retry_backoff_seconds
    raise Timeout::Error, 'HTTP tool flow exceeded its runtime limit' if flow_time_remaining <= delay

    sleep(delay)
  end

  def idempotent_retryable_http_method?
    AUTO_RETRYABLE_HTTP_METHODS.include?(@custom_tool.http_method.to_s)
  end

  def allowlisted_retryable_post_tool?
    @custom_tool.http_method.to_s == 'POST' && AUTO_RETRYABLE_CUSTOM_TOOL_SLUGS.include?(@custom_tool.slug.to_s)
  end

  def retry_remaining?(attempt_index, attempts)
    attempt_index < attempts - 1
  end

  def log_retry_attempt(reason, attempt, attempts)
    Rails.logger.warn(
      "HttpTool retrying #{@custom_tool.slug}: attempt #{attempt}/#{attempts} failed with #{reason}"
    )
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
