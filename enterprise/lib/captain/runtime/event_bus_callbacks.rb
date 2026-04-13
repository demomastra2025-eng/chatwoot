# frozen_string_literal: true

class Captain::Runtime::EventBusCallbacks
  EVENT_BUS_STATE_KEY = :__llm_event_bus
  PREVIEW_LIMIT = 500

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

  def on_llm_call_complete(agent_name, model, response, context_wrapper)
    publish(
      'chat.complete',
      context_wrapper,
      agent_name: agent_name,
      model: model,
      schema_name: current_chat_state(context_wrapper)[:schema_name],
      prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
      completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil,
      total_tokens: total_tokens(response),
      tool_call: response.respond_to?(:tool_call?) ? response.tool_call? : false,
      output_type: response.respond_to?(:content) ? payload_type(response.content) : nil,
      output_size: response.respond_to?(:content) ? payload_size(response.content) : nil
    )
  end

  def on_tool_start(tool_name, args, context_wrapper)
    publish(
      'tool.execute',
      context_wrapper,
      tool_name: tool_name,
      arguments_keys: args.respond_to?(:keys) ? args.keys.map(&:to_s) : [],
      arguments_size: payload_size(args),
      arguments_preview: preview_payload(args)
    )
  end

  def on_tool_complete(tool_name, result, context_wrapper)
    normalized_result = Captain::ToolResult.normalize(result)

    publish(
      'tool.complete',
      context_wrapper,
      tool_name: tool_name,
      result_type: payload_type(result),
      result_size: payload_size(result),
      error: tool_error?(result),
      result_success: normalized_result[:success],
      result_retryable: normalized_result[:retryable],
      result_message_preview: preview_payload(normalized_result[:message]),
      result_error_preview: preview_payload(normalized_result[:error])
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
      total_tokens: usage.total_tokens
    }
  end

  def total_tokens(response)
    return unless response.respond_to?(:input_tokens)

    (response.input_tokens || 0) + (response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0)
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

  def preview_payload(value)
    case value
    when Hash, Array
      value.to_json.first(PREVIEW_LIMIT)
    else
      value.to_s.first(PREVIEW_LIMIT)
    end
  end
end
