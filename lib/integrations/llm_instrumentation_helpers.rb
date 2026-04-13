# frozen_string_literal: true

module Integrations::LlmInstrumentationHelpers
  include Integrations::LlmInstrumentationConstants
  include Integrations::LlmInstrumentationCompletionHelpers

  def determine_provider(model_name)
    return 'openai' if model_name.blank?

    model = model_name.to_s.downcase

    LlmConstants::PROVIDER_PREFIXES.each do |provider, prefixes|
      return provider if prefixes.any? { |prefix| model.start_with?(prefix) }
    end

    'openai'
  end

  private

  def setup_span_attributes(span, params)
    set_request_attributes(span, params)
    set_prompt_messages(span, params[:messages], params)
    set_metadata_attributes(span, params)
  end

  def record_completion(span, result, params)
    if result.respond_to?(:content)
      span.set_attribute(ATTR_GEN_AI_COMPLETION_ROLE, result.role.to_s) if result.respond_to?(:role)
      content = capture_trace_output(result.content, params)
      span.set_attribute(ATTR_GEN_AI_COMPLETION_CONTENT, content) if content.present?
    elsif result.is_a?(Hash)
      set_completion_attributes(span, result, params)
    end
  end

  def set_request_attributes(span, params)
    provider = determine_provider(params[:model])
    span.set_attribute(ATTR_GEN_AI_PROVIDER, provider)
    span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, params[:model])
    span.set_attribute(ATTR_GEN_AI_REQUEST_TEMPERATURE, params[:temperature]) if params[:temperature]
  end

  def set_prompt_messages(span, messages, params)
    return unless messages.respond_to?(:each_with_index)

    messages.each_with_index do |msg, idx|
      role = msg[:role] || msg['role']
      content = msg[:content] || msg['content']

      span.set_attribute(format(ATTR_GEN_AI_PROMPT_ROLE, idx), role)
      captured_content = capture_trace_input(content, params)
      span.set_attribute(format(ATTR_GEN_AI_PROMPT_CONTENT, idx), captured_content) if captured_content.present?
    end
  end

  def set_metadata_attributes(span, params)
    session_id = params[:conversation_id].present? ? "#{params[:account_id]}_#{params[:conversation_id]}" : nil
    span.set_attribute(ATTR_LANGFUSE_USER_ID, params[:account_id].to_s) if params[:account_id]
    span.set_attribute(ATTR_LANGFUSE_SESSION_ID, session_id) if session_id.present?
    span.set_attribute(ATTR_LANGFUSE_TAGS, [params[:feature_name]].to_json) if params[:feature_name]

    trace_capture_attributes(params).each do |key, value|
      span.set_attribute(key, value)
    end

    return unless params[:metadata].is_a?(Hash)

    params[:metadata].each do |key, value|
      span.set_attribute(format(ATTR_LANGFUSE_METADATA, key), value.to_s)
    end
  end

  def trace_capture_attributes(params)
    Llm::TracePayloadPolicy.trace_attributes(
      account: trace_account(params),
      preferences: trace_preferences(params)
    )
  end

  def capture_trace_input(value, params)
    Llm::TracePayloadPolicy.capture(
      value,
      direction: :input,
      account: trace_account(params),
      preferences: trace_preferences(params)
    )
  end

  def capture_trace_output(value, params)
    Llm::TracePayloadPolicy.capture(
      value,
      direction: :output,
      account: trace_account(params),
      preferences: trace_preferences(params)
    )
  end

  def trace_account(params)
    return params[:account] if params[:account].is_a?(Account)
    return resolve_account(params) if respond_to?(:resolve_account, true)

    nil
  end

  def trace_preferences(params)
    preferences = params[:trace_preferences]
    return preferences.to_h.stringify_keys if preferences.respond_to?(:to_h)

    account = trace_account(params)
    return account.captain_preferences[:runtime].to_h.stringify_keys if account.respond_to?(:captain_preferences)

    {}
  end
end
