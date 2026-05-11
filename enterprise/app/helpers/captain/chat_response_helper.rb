module Captain::ChatResponseHelper
  include Integrations::LlmInstrumentationConstants

  private

  def build_response(response)
    Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }

    parsed = normalize_response_content(response.content)
    parsed = moderate_response_payload(parsed) if respond_to?(:moderate_response_payload, true)
    parsed['usage'] = usage_payload(response)

    persist_message(persistable_response(parsed), 'assistant')
    attach_tool_trace(parsed)
    parsed
  end

  def build_fallback_response(payload)
    parsed = normalize_response_content(payload)
    parsed = moderate_response_payload(parsed) if respond_to?(:moderate_response_payload, true)
    parsed['usage'] ||= zero_usage_payload

    persist_message(persistable_response(parsed), 'assistant')
    attach_tool_trace(parsed)
    parsed
  end

  def normalize_response_content(content)
    return content.with_indifferent_access if content.respond_to?(:with_indifferent_access)
    return content.to_h.with_indifferent_access if content.respond_to?(:to_h)

    { 'content' => content.to_s }
  end

  def usage_payload(response)
    {
      'prompt_tokens' => response.try(:input_tokens),
      'completion_tokens' => response.try(:output_tokens),
      'total_tokens' => response.try(:input_tokens).to_i + response.try(:output_tokens).to_i
    }
  end

  def zero_usage_payload
    {
      'prompt_tokens' => 0,
      'completion_tokens' => 0,
      'total_tokens' => 0
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

  def append_tool_trace_step(tool_name, event, input: nil, output: nil)
    @tool_trace_steps ||= []
    @tool_trace_sequence = @tool_trace_sequence.to_i + 1
    @tool_trace_steps << Captain::ToolTraceBuilder.step(
      tool_name: tool_name,
      event: event,
      sequence: @tool_trace_sequence,
      input: input,
      output: output
    )
  end
end
