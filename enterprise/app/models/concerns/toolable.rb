module Concerns::Toolable
  extend ActiveSupport::Concern

  def tool(assistant)
    custom_tool_record = self
    # Convert slug to valid Ruby constant name (replace hyphens with underscores, then camelize)
    class_name = custom_tool_record.slug.underscore.camelize

    # Always create a fresh class to reflect current metadata
    tool_class = Class.new(Captain::Tools::HttpTool) do
      description custom_tool_record.description

      custom_tool_record.runtime_parameter_definitions(Captain::ToolAccess::SCOPE_AGENT).each do |param_def|
        param param_def['name'].to_sym,
              type: param_def['type'],
              desc: param_def['description'],
              required: param_def.fetch('required', false)
      end
    end

    # Register the dynamically created class as a constant in the Captain::Tools namespace.
    # This is required because RubyLLM's Tool base class derives the tool name from the class name
    # (via Class#name). Anonymous classes created with Class.new have no name and return empty strings,
    # which causes "Invalid 'tools[].function.name': empty string" errors from the LLM API.
    # By setting it as a constant, the class gets a proper name (e.g., "Captain::Tools::CatFactLookup")
    # which RubyLLM extracts and normalizes to "cat-fact-lookup" for the LLM API.
    # We refresh the constant on each call to ensure tool metadata changes are reflected.
    Captain::Tools.send(:remove_const, class_name) if Captain::Tools.const_defined?(class_name, false)
    Captain::Tools.const_set(class_name, tool_class)

    tool_class.new(assistant, self)
  end

  def copilot_tool(assistant, user: nil, conversation: nil)
    Captain::Tools::Copilot::CustomHttpTool.new(
      assistant,
      self,
      user: user,
      conversation: conversation
    )
  end

  def build_request_url(params, template_context: params)
    return endpoint_url if endpoint_url.blank? || endpoint_url.exclude?('{{')

    render_template(endpoint_url, template_context)
  end

  def build_request_body(params, template_context: params)
    return nil if request_template.blank?

    render_template(request_template, template_context)
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

    {}.tap do |headers|
      add_base_headers(headers, state)
      add_conversation_headers(headers, conversation_context) if conversation_context
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
