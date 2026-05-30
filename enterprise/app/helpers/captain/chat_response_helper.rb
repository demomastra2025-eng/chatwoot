module Captain::ChatResponseHelper
  include Integrations::LlmInstrumentationConstants

  private

  def build_response(response)
    Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }

    parsed = normalize_response_content(response.content)
    parsed = normalize_ui_actions_payload(parsed)
    parsed = moderate_response_payload(parsed) if respond_to?(:moderate_response_payload, true)
    parsed['usage'] = usage_payload(response)
    attach_tool_trace(parsed)

    persist_message(persistable_response(parsed), 'assistant')
    parsed
  end

  def build_fallback_response(payload)
    parsed = normalize_response_content(payload)
    parsed = normalize_ui_actions_payload(parsed)
    parsed = moderate_response_payload(parsed) if respond_to?(:moderate_response_payload, true)
    parsed['usage'] ||= zero_usage_payload
    attach_tool_trace(parsed)

    persist_message(persistable_response(parsed), 'assistant')
    parsed
  end

  def normalize_response_content(content)
    return content.with_indifferent_access if content.respond_to?(:with_indifferent_access)
    return content.to_h.with_indifferent_access if content.respond_to?(:to_h)

    { 'content' => content.to_s }
  end

  def normalize_ui_actions_payload(parsed_response)
    return parsed_response unless parsed_response.key?('ui_actions') || parsed_response.key?(:ui_actions)

    raw_actions = parsed_response['ui_actions'] || parsed_response[:ui_actions]
    parsed_response.delete('ui_actions')
    parsed_response.delete(:ui_actions)
    parsed_response['ui_actions'] = Captain::UiActionContract.normalize(raw_actions)
    parsed_response
  end

  def usage_payload(response)
    {
      'prompt_tokens' => response.try(:input_tokens),
      'completion_tokens' => response.try(:output_tokens),
      'thinking_tokens' => response.try(:thinking_tokens),
      'total_tokens' => response.try(:input_tokens).to_i + response.try(:output_tokens).to_i
    }.compact
  end

  def zero_usage_payload
    {
      'prompt_tokens' => 0,
      'completion_tokens' => 0,
      'total_tokens' => 0
    }
  end

  def persistable_response(parsed_response)
    parsed_response.except('usage')
  end

  def persist_thinking_message(tool_call)
    tool_name = tool_call.name.to_s
    call_id = tool_call_id(tool_call)
    trace_step = append_tool_trace_step(
      tool_name,
      'start',
      input: tool_call.arguments,
      tool_call_id: call_id
    )

    return if @copilot_thread.blank?

    persist_tool_trace_message(
      content: "Using #{tool_name}",
      tool_name: tool_name,
      call_id: call_id,
      status: trace_step['status'],
      input: trace_step['input']
    )
  end

  def persist_tool_completion(result)
    return unless (tool_call = @pending_tool_calls&.pop)

    tool_name = tool_call.name.to_s
    call_id = tool_call_id(tool_call)
    normalized_result = Captain::ToolResult.normalize(result)
    event = Captain::ToolResult.error?(normalized_result) ? 'failed' : 'finish'
    trace_step = append_tool_trace_step(
      tool_name,
      event,
      output: normalized_result,
      tool_call_id: call_id
    )

    return if @copilot_thread.blank?

    persist_tool_trace_message(
      content: tool_completion_content(tool_name, event),
      tool_name: tool_name,
      call_id: call_id,
      status: trace_step['status'],
      output: trace_step['output']
    )
  end

  def persist_tool_trace_message(content:, tool_name:, call_id:, status:, **payload)
    persist_message(
      {
        'content' => content,
        'function_name' => tool_name,
        'tool_call_id' => call_id,
        'status' => status
      }.merge(payload).compact,
      'assistant_thinking'
    )
  end

  def tool_completion_content(tool_name, event)
    event == 'failed' ? "Failed #{tool_name}" : "Completed #{tool_name}"
  end

  def attach_tool_trace(parsed_response)
    payload = Captain::ToolTraceBuilder.payload(@tool_trace_steps)
    parsed_response['captain_trace'] = payload if payload.present?
  end

  def append_tool_trace_step(tool_name, event, **options)
    @tool_trace_steps ||= []
    @tool_trace_sequence = @tool_trace_sequence.to_i + 1
    trace_step = Captain::ToolTraceBuilder.step(
      tool_name: tool_name,
      event: event,
      sequence: @tool_trace_sequence,
      tool_call_id: options[:tool_call_id],
      input: options[:input],
      output: options[:output]
    )
    @tool_trace_steps << trace_step
    trace_step
  end

  def tool_call_id(tool_call)
    return unless tool_call.respond_to?(:id)

    tool_call.id
  end
end
