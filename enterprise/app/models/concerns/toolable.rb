module Concerns::Toolable
  extend ActiveSupport::Concern

  module JsonRequestFilters
    def json_request_value(input)
      encoded_value = JSON.generate(Captain::EncodingNormalizer.utf8(input))
      input.is_a?(String) ? encoded_value[1...-1] : encoded_value
    end
  end

  # Isolated namespace for user-defined custom tool classes.
  # Keeps them separate from built-in classes in Captain::Tools.
  module CustomTools; end

  def tool(assistant, base_class: Captain::Tools::HttpTool, **)
    custom_tool_record = self
    class_name = custom_tool_record.slug.underscore.camelize

    # Always create a fresh class to reflect current metadata
    tool_slug = custom_tool_record.slug
    tool_class = Class.new(base_class) do
      description custom_tool_record.description

      # Use the slug as-is so the LLM receives the configured tool name,
      # not a Ruby namespace-derived name.
      define_method(:name) { tool_slug }

      custom_tool_record.runtime_parameter_definitions(Captain::ToolAccess::SCOPE_AGENT).each do |param_def|
        param param_def['name'].to_sym,
              type: param_def['type'],
              desc: param_def['description'],
              required: param_def.fetch('required', false)
      end
    end

    # Register as a constant so Class#name is present while avoiding collisions
    # with built-in Captain::Tools constants.
    CustomTools.send(:remove_const, class_name) if CustomTools.const_defined?(class_name, false)
    CustomTools.const_set(class_name, tool_class)

    tool_class.new(assistant, self, **)
  end

  def copilot_tool(assistant, user: nil, conversation: nil, copilot_thread: nil)
    Captain::Tools::Copilot::CustomHttpTool.new(
      assistant,
      self,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
  end

  def build_request_url(params, template_context: params)
    built_url = if endpoint_url.blank? || endpoint_url.exclude?('{{')
                  endpoint_url
                else
                  render_template(endpoint_url, template_context)
                end

    apply_query_auth_to_url(apply_query_params_to_url(built_url, params))
  end

  def build_request_body(params, template_context: params)
    return nil if request_template.blank?

    return render_template(request_template, template_context) unless request_body_form_urlencoded?

    encode_form_request_body(render_form_request_template(request_template, template_context))
  end

  def request_content_type
    request_body_form_urlencoded? ? 'application/x-www-form-urlencoded' : 'application/json'
  end

  def build_request_headers(params)
    request_params_for_location(Captain::CustomTool::PARAM_REQUEST_LOCATION_HEADER, params)
  end

  def build_auth_headers
    return {} if auth_none?

    case auth_type
    when 'bearer'
      { 'Authorization' => "Bearer #{auth_config['token']}" }
    when 'api_key'
      if auth_config['location'] == 'header'
        { auth_config['name'] => auth_config['key'] }
      else
        {}
      end
    else
      {}
    end
  end

  def build_basic_auth_credentials
    return nil unless auth_type == 'basic'

    [auth_config['username'], auth_config['password']]
  end

  def build_metadata_headers(state)
    prompt_context = state[:prompt_context] || {}
    prompt_context = prompt_context.with_indifferent_access if prompt_context.respond_to?(:with_indifferent_access)
    conversation_context = state.key?(:prompt_context) ? prompt_context[:conversation] : state[:conversation]
    contact_context = state.key?(:prompt_context) ? prompt_context[:contact] : state[:contact]
    deal_context = state.key?(:prompt_context) ? prompt_context[:deal] : state[:deal]
    task_context = state.key?(:prompt_context) ? prompt_context[:task] : state[:task]
    appointment_context = state.key?(:prompt_context) ? prompt_context[:appointment] : state[:appointment]
    communication_thread_context = state.key?(:prompt_context) ? prompt_context[:communication_thread] : state[:communication_thread]

    {}.tap do |headers|
      add_base_headers(headers, state)
      add_conversation_headers(headers, conversation_context) if conversation_context
      add_communication_thread_headers(headers, communication_thread_context) if communication_thread_context
      add_contact_headers(headers, contact_context) if contact_context
      add_deal_headers(headers, deal_context) if deal_context
      add_task_headers(headers, task_context) if task_context
      add_appointment_headers(headers, appointment_context) if appointment_context
      add_contact_inbox_headers(headers, state[:contact_inbox])
    end
  end

  def add_base_headers(headers, state)
    headers['X-Chatwoot-Account-Id'] = state[:account_id].to_s if state[:account_id]
    headers['X-Chatwoot-Assistant-Id'] = state[:assistant_id].to_s if state[:assistant_id]
    headers['X-Chatwoot-Tool-Slug'] = slug if slug.present?
  end

  def add_conversation_headers(headers, conversation)
    headers['X-Chatwoot-Conversation-Id'] = conversation[:id].to_s if conversation[:id]
    headers['X-Chatwoot-Conversation-Display-Id'] = conversation[:display_id].to_s if conversation[:display_id]
  end

  def add_communication_thread_headers(headers, communication_thread)
    headers['X-Chatwoot-Communication-Thread-Id'] = communication_thread[:id].to_s if communication_thread[:id]
    if communication_thread[:display_id]
      headers['X-Chatwoot-Communication-Thread-Display-Id'] = communication_thread[:display_id].to_s
    end

    conversation_ids = Array(communication_thread[:conversation_ids]).compact
    headers['X-Chatwoot-Communication-Thread-Conversation-Ids'] = conversation_ids.join(',') if conversation_ids.present?

    channel_key = communication_thread[:current_channel_key] || communication_thread.dig(:current_channel, :channel_key)
    headers['X-Chatwoot-Communication-Thread-Channel-Key'] = channel_key.to_s if channel_key.present?
  end

  def add_contact_headers(headers, contact)
    headers['X-Chatwoot-Contact-Id'] = contact[:id].to_s if contact[:id]
    headers['X-Chatwoot-Contact-Email'] = contact[:email].to_s if contact[:email].present?
    headers['X-Chatwoot-Contact-Phone'] = contact[:phone_number].to_s if contact[:phone_number].present?
  end

  def add_deal_headers(headers, deal)
    headers['X-Chatwoot-Deal-Id'] = deal[:id].to_s if deal[:id]
    headers['X-Chatwoot-Deal-Title'] = deal[:title].to_s if deal[:title].present?
    headers['X-Chatwoot-Deal-Stage'] = deal[:stage_name].to_s if deal[:stage_name].present?
  end

  def add_task_headers(headers, task)
    headers['X-Chatwoot-Task-Id'] = task[:id].to_s if task[:id]
    headers['X-Chatwoot-Task-Title'] = task[:title].to_s if task[:title].present?
    headers['X-Chatwoot-Task-Status'] = task[:status_name].to_s if task[:status_name].present?
  end

  def add_appointment_headers(headers, appointment)
    headers['X-Chatwoot-Appointment-Id'] = appointment[:id].to_s if appointment[:id]
    headers['X-Chatwoot-Appointment-Status'] = appointment[:status].to_s if appointment[:status].present?
    headers['X-Chatwoot-Appointment-Starts-At'] = appointment[:starts_at].to_s if appointment[:starts_at].present?
  end

  def add_contact_inbox_headers(headers, contact_inbox)
    headers['X-Chatwoot-Contact-Inbox-Id'] = contact_inbox[:id].to_s if contact_inbox&.[](:id)
    headers['X-Chatwoot-Contact-Inbox-Verified'] = (contact_inbox&.[](:hmac_verified) || false).to_s
  end

  def format_response(raw_response_body)
    return raw_response_body if response_template.blank?

    response_data = parse_response_body(raw_response_body)
    render_template(response_template, { 'response' => response_data, 'r' => response_data })
  end

  private

  def render_form_request_template(template, context)
    escaped_template = template.gsub(/\{\{(.*?)\}\}/m) do
      "{{#{Regexp.last_match(1)} | json_request_value }}"
    end

    Captain::PromptRegistry.render_inline!(
      escaped_template,
      variables: context,
      filters: [JsonRequestFilters]
    )
  end

  def encode_form_request_body(rendered_body)
    form_fields = JSON.parse(rendered_body)
    raise ArgumentError, 'URL-encoded request body template must render a JSON object' unless form_fields.is_a?(Hash)

    URI.encode_www_form(form_request_pairs(form_fields))
  rescue JSON::ParserError
    raise ArgumentError, 'URL-encoded request body template must render a JSON object'
  end

  def form_request_pairs(form_fields)
    form_fields.flat_map do |key, value|
      values = value.is_a?(Array) ? value : [value]
      values.map { |item| [key, form_request_value(item)] }
    end
  end

  def form_request_value(value)
    return JSON.generate(Captain::EncodingNormalizer.utf8(value)) if value.is_a?(Hash) || value.is_a?(Array)

    value
  end

  def apply_query_params_to_url(url, params)
    query_params = request_params_for_location(Captain::CustomTool::PARAM_REQUEST_LOCATION_QUERY, params)
    return url if query_params.empty?

    uri = URI.parse(url)
    query_pairs = URI.decode_www_form(uri.query.to_s)
    query_params.each do |key, value|
      query_pairs.reject! { |existing_key, _existing_value| existing_key == key }
      query_pairs << [key, value]
    end
    uri.query = URI.encode_www_form(query_pairs)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  def request_params_for_location(location, params)
    stringified_params = params.deep_stringify_keys

    parameter_definitions.each_with_object({}) do |definition, request_params|
      next unless definition['request_location'] == location

      value = stringified_params[definition['name']]
      next if value.nil?

      request_params[definition['request_key']] = request_param_value(value)
    end
  end

  def request_param_value(value)
    if value.is_a?(Hash) || value.is_a?(Array)
      JSON.generate(Captain::EncodingNormalizer.utf8(value))
    else
      value.to_s
    end
  end

  def apply_query_auth_to_url(url)
    return url unless auth_type == 'api_key'
    return url unless auth_config['location'] == 'query'
    return url if auth_config['name'].blank? || auth_config['key'].blank?

    uri = URI.parse(url)
    query_pairs = URI.decode_www_form(uri.query.to_s)
    query_pairs.reject! { |key, _value| key == auth_config['name'] }
    query_pairs << [auth_config['name'], auth_config['key'].to_s]
    uri.query = URI.encode_www_form(query_pairs)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  def render_template(template, context)
    Captain::PromptRegistry.render_inline!(template, variables: context)
  rescue Liquid::SyntaxError, Liquid::UndefinedVariable, Liquid::UndefinedFilter => e
    Rails.logger.error("Liquid template error: #{e.message}")
    raise "Template rendering failed: #{e.message}"
  end

  def parse_response_body(body)
    return body if body.blank?

    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    body
  end
end
