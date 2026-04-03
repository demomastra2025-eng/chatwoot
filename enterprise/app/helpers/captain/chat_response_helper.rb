module Captain::ChatResponseHelper
  include Integrations::LlmInstrumentationConstants

  private

  def build_response(response)
    Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }

    parsed = parse_json_response(response.content)
    parsed['usage'] = usage_payload(response)
    apply_credit_usage_metadata(parsed)

    persist_message(persistable_response(parsed), 'assistant')
    attach_tool_trace(parsed)
    parsed
  end

  def parse_json_response(content)
    content = content.gsub('```json', '').gsub('```', '')
    content = content.strip
    JSON.parse(content)
  rescue JSON::ParserError => e
    Rails.logger.error "#{self.class.name} Assistant: #{@assistant.id}, Error parsing JSON response: #{e.message}"
    { 'content' => content }
  end

  def apply_credit_usage_metadata(parsed_response)
    return unless captain_v1_assistant?

    OpenTelemetry::Trace.current_span.set_attribute(
      format(ATTR_LANGFUSE_METADATA, 'credit_used'),
      credit_used_for_response?(parsed_response).to_s
    )
  rescue StandardError => e
    Rails.logger.warn "#{self.class.name} Assistant: #{@assistant.id}, Failed to set credit usage metadata: #{e.message}"
  end

  def credit_used_for_response?(parsed_response)
    response = parsed_response['response']
    response.present? && response != 'conversation_handoff'
  end

  def captain_v1_assistant?
    feature_name == 'assistant' && !@assistant.account.feature_enabled?('captain_integration_v2')
  end

  def usage_payload(response)
    {
      'prompt_tokens' => response.try(:input_tokens),
      'completion_tokens' => response.try(:output_tokens),
      'total_tokens' => response.try(:input_tokens).to_i + response.try(:output_tokens).to_i
    }
  end

  def persistable_response(parsed_response)
    parsed_response.except('usage', 'captain_trace')
  end

  def persist_thinking_message(tool_call)
    tool_name = tool_call.name.to_s
    append_tool_trace_step(tool_name, 'start')

    return if @copilot_thread.blank?

    persist_message(
      {
        'content' => "Using #{tool_name}",
        'function_name' => tool_name
      },
      'assistant_thinking'
    )
  end

  def persist_tool_completion
    tool_call = @pending_tool_calls&.pop
    return unless tool_call

    tool_name = tool_call.name.to_s
    append_tool_trace_step(tool_name, 'complete')

    return if @copilot_thread.blank?

    persist_message(
      {
        'content' => "Completed #{tool_name}",
        'function_name' => tool_name
      },
      'assistant_thinking'
    )
  end

  def attach_tool_trace(parsed_response)
    payload = Captain::ToolTraceBuilder.payload(@tool_trace_steps)
    parsed_response['captain_trace'] = payload if payload.present?
  end

  def append_tool_trace_step(tool_name, event)
    @tool_trace_steps ||= []
    @tool_trace_sequence = @tool_trace_sequence.to_i + 1
    @tool_trace_steps << Captain::ToolTraceBuilder.step(
      tool_name: tool_name,
      event: event,
      sequence: @tool_trace_sequence
    )
  end
end
