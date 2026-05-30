module Captain::ChatHelper
  include Integrations::LlmInstrumentation
  include Captain::ChatResponseHelper
  include Captain::ChatGenerationRecorder

  def request_chat_completion
    log_chat_completion_request
    response = with_agent_session do
      Llm::ChatRequestRunner.new(
        chat: chat(model: model, temperature: temperature, thinking: llm_thinking_options),
        model: model,
        account: llm_model_account,
        messages: @messages,
        tools: @tools,
        schema: response_schema,
        on_end_message: ->(runner_chat, message) { record_llm_generation(runner_chat, message) },
        on_tool_call: ->(tool_call) { handle_tool_call(tool_call) },
        on_tool_result: ->(result) { handle_tool_result(result) },
        content_builder: ->(content) { build_ruby_llm_content(content) },
        observability: chat_observability_payload
      ).call
    end

    build_response(response)
  rescue Llm::StructuredOutputPolicy::StructuredOutputError => e
    Rails.logger.error "#{self.class.name} Assistant: #{@assistant.id}, Structured output failure: #{e}"

    fallback_payload = structured_output_fallback_payload(e)
    raise e if fallback_payload.blank?

    build_fallback_response(fallback_payload)
  rescue StandardError => e
    Rails.logger.error "#{self.class.name} Assistant: #{@assistant.id}, Error in chat completion: #{e}"
    raise e
  end

  private

  def handle_tool_call(tool_call)
    persist_thinking_message(tool_call)
    start_tool_span(tool_call)
    (@pending_tool_calls ||= []).push(tool_call)
  end

  def handle_tool_result(result)
    end_tool_span(result)
    persist_tool_completion(result)
  end

  def build_ruby_llm_content(content)
    Llm::MessageFormat.build_content(content)
  end

  def chat_observability_payload
    {
      feature: feature_name,
      runtime_mode: 'captain_chat',
      account_id: resolved_account_id,
      assistant_id: @assistant&.id,
      conversation_record_id: @conversation&.id,
      conversation_display_id: @conversation&.display_id || @conversation_id,
      copilot_thread_id: @copilot_thread&.id,
      session_id: respond_to?(:copilot_session_id, true) ? send(:copilot_session_id) : nil,
      channel_type: resolved_channel_type,
      source: @source,
      model: model
    }.compact
  end

  def instrumentation_params(chat = nil)
    trace_account = @account || @assistant&.account
    {
      span_name: "llm.captain.#{feature_name}",
      account_id: resolved_account_id,
      account: trace_account,
      conversation_id: @conversation_id,
      feature_name: feature_name,
      model: model,
      messages: chat ? chat.messages.map { |m| { role: m.role.to_s, content: m.content.to_s } } : @messages,
      temperature: temperature,
      trace_preferences: trace_account&.captain_preferences&.dig(:runtime),
      metadata: {
        assistant_id: @assistant&.id,
        channel_type: resolved_channel_type,
        source: @source
      }.compact
    }
  end

  def temperature
    raw_temperature = @assistant&.config&.[]('temperature')
    (raw_temperature.presence || 1).to_f
  end

  def resolved_account_id
    @account&.id || @assistant&.account_id
  end

  def resolved_channel_type
    @conversation&.inbox&.channel_type
  end

  # Ensures all LLM calls and tool executions within an agentic loop
  # are grouped under a single trace/session in Langfuse.
  #
  # Without this guard, each recursive call to request_chat_completion
  # (triggered by tool calls) would create a separate trace instead of
  # nesting within the existing session span.
  def with_agent_session(&)
    already_active = @agent_session_active
    return yield if already_active

    @agent_session_active = true
    instrument_agent_session(instrumentation_params, &)
  ensure
    @agent_session_active = false unless already_active
  end

  # Must be implemented by including class to identify the feature for instrumentation.
  # Used for Langfuse tagging and span naming.
  def feature_name
    raise NotImplementedError, "#{self.class.name} must implement #feature_name"
  end

  def log_chat_completion_request
    Rails.logger.info("#{self.class.name} Assistant: #{@assistant.id}, requesting completion for #{@messages} with #{@tools&.length || 0} tools")
  end

  def moderate_input_content(_content)
    nil
  end

  def response_schema
    nil
  end

  def structured_output_fallback_payload(_error)
    nil
  end
end
