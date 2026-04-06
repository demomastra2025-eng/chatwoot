module Captain::ChatHelper
  include Integrations::LlmInstrumentation
  include Captain::ChatResponseHelper
  include Captain::ChatGenerationRecorder

  def request_chat_completion
    log_chat_completion_request
    response = with_agent_session do
      Llm::ChatRequestRunner.new(
        chat: chat(model: model, temperature: temperature, thinking: llm_thinking_options),
        messages: @messages,
        tools: @tools,
        schema: response_schema,
        on_end_message: ->(runner_chat, message) { record_llm_generation(runner_chat, message) },
        on_tool_call: ->(tool_call) { handle_tool_call(tool_call) },
        on_tool_result: ->(result) { handle_tool_result(result) },
        content_builder: ->(content) { build_ruby_llm_content(content) }
      ).call
    end

    build_response(response)
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
    persist_tool_completion
  end

  def build_ruby_llm_content(content)
    return content if content.is_a?(RubyLLM::Content)

    text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(content)
    attachments.any? ? RubyLLM::Content.new(text, attachments) : text
  end

  def instrumentation_params(chat = nil)
    {
      span_name: "llm.captain.#{feature_name}",
      account_id: resolved_account_id,
      conversation_id: @conversation_id,
      feature_name: feature_name,
      model: model,
      messages: chat ? chat.messages.map { |m| { role: m.role.to_s, content: m.content.to_s } } : @messages,
      temperature: temperature,
      metadata: {
        assistant_id: @assistant&.id,
        channel_type: resolved_channel_type,
        source: @source
      }.compact
    }
  end

  def temperature
    @assistant&.config&.[]('temperature').to_f || 1
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
end
