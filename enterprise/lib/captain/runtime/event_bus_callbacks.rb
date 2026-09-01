# frozen_string_literal: true

class Captain::Runtime::EventBusCallbacks
  EVENT_BUS_STATE_KEY = :__llm_event_bus

  def on_run_start(agent_name, input, context_wrapper)
    publish(
      'run.start',
      context_wrapper,
      agent_name: agent_name,
      input_type: payload_type(input),
      input_size: payload_size(input)
    )
  end

  def on_chat_created(chat, agent_name, model, context_wrapper)
    event_bus_state(context_wrapper)[:current_chat] = {
      agent_name: agent_name,
      model: model,
      schema_name: schema_name_for(chat)
    }
  end

  def on_llm_call_complete(agent_name, model, response, context_wrapper, metadata = {})
    publish(
      'chat.complete',
      context_wrapper,
      agent_name: agent_name,
      model: model,
      schema_name: current_chat_state(context_wrapper)[:schema_name],
      prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
      completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil,
      thinking_tokens: thinking_tokens(response),
      total_tokens: total_tokens(response),
      usage_counted: metadata[:provider_usage_recorded] ? false : nil,
      tool_call: response.respond_to?(:tool_call?) ? response.tool_call? : false,
      output_type: response.respond_to?(:content) ? payload_type(response.content) : nil,
      output_size: response.respond_to?(:content) ? payload_size(response.content) : nil
    )
  end

  def on_tool_start(tool_name, args, context_wrapper)
    push_tool_timing(context_wrapper, tool_name)
    publish(
      'tool.execute',
      context_wrapper,
      tool_name: tool_name,
      arguments_keys: args.respond_to?(:keys) ? args.keys.map(&:to_s) : [],
      arguments_size: payload_size(args)
    )
  end

  def on_tool_requested(tool_name, args, context_wrapper)
    publish(
      'tool.requested',
      context_wrapper,
      tool_name: tool_name,
      arguments_keys: args.respond_to?(:keys) ? args.keys.map(&:to_s) : [],
      arguments_size: payload_size(args)
    )
  end

  def on_tool_progress(tool_name, details, context_wrapper)
    publish(
      'tool.progress',
      context_wrapper,
      tool_name: tool_name,
      progress_type: payload_type(details),
      progress_size: payload_size(details)
    )
  end

  def on_tool_complete(tool_name, result, context_wrapper)
    normalized_result = Captain::ToolResult.normalize(result)
    timing = pop_tool_timing(context_wrapper, tool_name)

    publish(
      'tool.complete',
      context_wrapper,
      tool_name: tool_name,
      result_type: payload_type(result),
      result_size: payload_size(result),
      error: tool_error?(result),
      result_success: normalized_result[:success],
      result_retryable: normalized_result[:retryable],
      result_message_type: payload_type(normalized_result[:message]),
      result_message_size: payload_size(normalized_result[:message]),
      result_error_type: payload_type(normalized_result[:error]),
      result_error_size: payload_size(normalized_result[:error]),
      duration_ms: timing[:duration_ms],
      started_at: timing[:started_at],
      completed_at: timing[:completed_at]
    )
  end

  def on_agent_handoff(from_agent, to_agent, reason, context_wrapper)
    publish(
      'agent.handoff',
      context_wrapper,
      from_agent: from_agent,
      to_agent: to_agent,
      reason: reason.to_s
    )
  end

  def on_run_complete(agent_name, result, context_wrapper)
    publish(
      'run.complete',
      context_wrapper,
      agent_name: agent_name,
      error: result.respond_to?(:error) && result.error.present?,
      output_type: result.respond_to?(:output) ? payload_type(result.output) : nil,
      output_size: result.respond_to?(:output) ? payload_size(result.output) : nil,
      thinking_tokens: result_usage_thinking_tokens(result),
      usage: usage_payload(result)
    )
  end

  private

  def publish(event_name, context_wrapper, payload = {})
    Llm::EventBus.publish(event_name, base_payload(context_wrapper).merge(payload).compact)
  end

  def base_payload(context_wrapper)
    state = context_wrapper&.context&.dig(:state) || {}
    conversation = state[:conversation] || {}

    {
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      assistant_id: state[:assistant_id],
      conversation_id: conversation[:id],
      conversation_display_id: conversation[:display_id],
      channel_type: state[:channel_type],
      source: state[:source],
      project_case_id: state[:project_case_id] || context_wrapper&.context&.dig(:project_case_id),
      current_agent: context_wrapper&.context&.dig(:current_agent),
      session_id: context_wrapper&.context&.dig(:session_id)
    }.merge(trace_payload(context_wrapper))
  end

  def trace_payload(context_wrapper)
    context_wrapper&.context&.dig(Captain::Runtime::TracingCallbacks::TRACE_EVENT_CONTEXT_KEY).to_h.symbolize_keys
  end

  def event_bus_state(context_wrapper)
    context_wrapper.context[EVENT_BUS_STATE_KEY] ||= {}
  end

  def push_tool_timing(context_wrapper, tool_name)
    event_bus_state(context_wrapper)[:tool_timings] ||= {}
    event_bus_state(context_wrapper)[:tool_timings][tool_name.to_s] ||= []
    event_bus_state(context_wrapper)[:tool_timings][tool_name.to_s] << {
      started_at: Time.current,
      started_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    }
  rescue StandardError
    nil
  end

  def pop_tool_timing(context_wrapper, tool_name)
    timing = event_bus_state(context_wrapper).dig(:tool_timings, tool_name.to_s)&.shift
    completed_at = Time.current
    return { completed_at: completed_at.iso8601(6) } if timing.blank?

    {
      started_at: timing[:started_at]&.iso8601(6),
      completed_at: completed_at.iso8601(6),
      duration_ms: elapsed_ms(timing[:started_monotonic])
    }.compact
  rescue StandardError
    {}
  end

  def elapsed_ms(started_monotonic)
    return if started_monotonic.blank?

    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) * 1000).round
  end

  def current_chat_state(context_wrapper)
    event_bus_state(context_wrapper)[:current_chat] || {}
  end

  def schema_name_for(chat)
    schema = Llm::StructuredOutputPolicy.schema_for(chat)
    return if schema.blank?

    schema.respond_to?(:name) && schema.name.present? ? schema.name : schema.class.name
  end

  def usage_payload(result)
    usage = result.respond_to?(:usage) ? result.usage : nil
    return if usage.blank?

    {
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      thinking_tokens: usage.respond_to?(:thinking_tokens) ? usage.thinking_tokens : nil
    }.compact
  end

  def result_usage_thinking_tokens(result)
    usage = result.respond_to?(:usage) ? result.usage : nil
    return unless usage.respond_to?(:thinking_tokens)

    usage.thinking_tokens.to_i.then { |tokens| tokens.positive? ? tokens : nil }
  end

  def total_tokens(response)
    return unless response.respond_to?(:input_tokens)

    (response.input_tokens || 0) + (response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0)
  end

  def thinking_tokens(response)
    tokens = response.thinking_tokens if response.respond_to?(:thinking_tokens)
    tokens ||= response.reasoning_tokens if response.respond_to?(:reasoning_tokens)

    tokens.to_i.positive? ? tokens.to_i : nil
  end

  def tool_error?(result)
    Captain::ToolResult.error?(result)
  end

  def payload_type(value)
    case value
    when RubyLLM::Content
      value.attachments.present? ? 'multimodal_content' : 'text_content'
    when Hash
      'hash'
    when Array
      'array'
    when NilClass
      'nil'
    else
      value.class.name.demodulize.underscore
    end
  end

  def payload_size(value)
    case value
    when RubyLLM::Content
      payload_size(Llm::MessageFormat.serialize_content(value))
    when Hash, Array
      value.to_json.bytesize
    else
      value.to_s.bytesize
    end
  end
end
