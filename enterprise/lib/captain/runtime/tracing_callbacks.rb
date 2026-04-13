# frozen_string_literal: true

require 'json'

class Captain::Runtime::TracingCallbacks
  include Integrations::LlmInstrumentationConstants
  TRACE_EVENT_CONTEXT_KEY = :__captain_trace_event

  def initialize(tracer:, trace_name:, span_attributes: {}, attribute_provider: nil)
    @tracer = tracer
    @trace_name = trace_name
    @llm_span_name = "#{trace_name}.generation"
    @tool_span_name = "#{trace_name}.tool.%s"
    @agent_span_name = "#{trace_name}.agent.%s"
    @handoff_event_name = "#{trace_name}.handoff"
    @span_attributes = span_attributes
    @attribute_provider = attribute_provider
  end

  def on_run_start(agent_name, input, context_wrapper)
    attributes = build_root_attributes(agent_name, input, context_wrapper)
    root_span = @tracer.start_span(@trace_name, attributes: attributes)
    root_context = OpenTelemetry::Trace.context_with_span(root_span)
    root_metadata = span_metadata(
      span: root_span,
      root_span: root_span,
      kind: 'trace',
      name: @trace_name
    )

    context_wrapper.context[:__otel_tracing] = {
      root_span: root_span,
      root_context: root_context,
      current_tool_span: nil,
      current_agent_name: nil,
      current_agent_span: nil,
      current_agent_context: nil,
      root_metadata: root_metadata,
      current_agent_metadata: nil,
      last_agent_metadata: nil,
      current_tool_metadata: nil,
      last_tool_metadata: nil,
      last_llm_metadata: nil
    }
    set_trace_event_context!(context_wrapper, root_metadata)
  end

  def on_agent_thinking(agent_name, input, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    tracing[:pending_llm_input] = trace_input_payload(input, context_wrapper, prefer_context: true)
    if tracing[:current_agent_name] == agent_name
      set_trace_event_context!(context_wrapper, tracing[:current_agent_metadata] || tracing[:root_metadata])
      return
    end

    start_agent_span(tracing, agent_name, context_wrapper)
    set_trace_event_context!(context_wrapper, tracing[:current_agent_metadata] || tracing[:root_metadata])
  end

  def on_llm_call_complete(_agent_name, _model, _response, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    set_trace_event_context!(
      context_wrapper,
      tracing[:last_llm_metadata] || tracing[:current_agent_metadata] || tracing[:root_metadata]
    )
  end

  def on_agent_complete(_agent_name, _result, _error, context_wrapper)
    tracing = tracing_state(context_wrapper)
    finish_agent_span(tracing) if tracing
  end

  def on_chat_created(chat, agent_name, model, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    chat.on_end_message do |message|
      handle_end_message(chat, agent_name, model, message, context_wrapper)
    end
  end

  def on_tool_start(tool_name, args, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    span_name = format(@tool_span_name, tool_name)
    attributes = {
      ATTR_LANGFUSE_OBSERVATION_TYPE => 'tool'
    }
    merge_trace_capture_attributes!(attributes, context_wrapper)
    input = trace_input_payload(args, context_wrapper)
    attributes[ATTR_LANGFUSE_OBSERVATION_INPUT] = input if input.present?

    parent_span = handoff_tool?(tool_name) ? tracing[:root_span] : parent_span_for(tracing)
    parent = handoff_tool?(tool_name) ? tracing[:root_context] : parent_context(tracing)
    tracing[:current_tool_span] = @tracer.start_span(span_name, with_parent: parent, attributes: attributes)
    tracing[:current_tool_metadata] = span_metadata(
      span: tracing[:current_tool_span],
      root_span: tracing[:root_span],
      parent_span: parent_span,
      kind: 'tool',
      name: span_name
    )
    set_trace_event_context!(context_wrapper, tracing[:current_tool_metadata])
  end

  def on_tool_complete(_tool_name, result, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    tool_span = tracing[:current_tool_span]
    return unless tool_span

    output = trace_output_payload(result, context_wrapper)
    tool_span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, output) if output.present?
    set_tool_result_attributes(tool_span, result, output)
    tracing[:last_tool_metadata] = tracing[:current_tool_metadata]
    set_trace_event_context!(context_wrapper, tracing[:last_tool_metadata] || tracing[:root_metadata])
    tool_span.finish
    tracing[:current_tool_span] = nil
    tracing[:current_tool_metadata] = nil
  end

  def on_agent_handoff(from_agent, to_agent, reason, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    tracing[:root_span]&.add_event(
      @handoff_event_name,
      attributes: {
        'handoff.from' => from_agent,
        'handoff.to' => to_agent,
        'handoff.reason' => reason.to_s
        }
    )
    set_trace_event_context!(
      context_wrapper,
      tracing[:last_agent_metadata] || tracing[:current_agent_metadata] || tracing[:root_metadata]
    )
  end

  def on_run_complete(_agent_name, result, context_wrapper)
    tracing = tracing_state(context_wrapper)
    return unless tracing

    finish_dangling_spans(tracing)

    root_span = tracing[:root_span]
    return unless root_span

    set_run_output_attributes(root_span, result, context_wrapper)
    set_run_error_status(root_span, result)
    set_trace_event_context!(context_wrapper, tracing[:root_metadata])
    root_span.finish
    context_wrapper.context.delete(:__otel_tracing)
  end

  private

  def tracing_state(context_wrapper)
    context_wrapper&.context&.dig(:__otel_tracing)
  end

  def handle_end_message(chat, _agent_name, model, message, context_wrapper)
    return unless message.respond_to?(:role) && message.role == :assistant

    tracing = tracing_state(context_wrapper)
    return unless tracing

    input = trace_input_payload(format_chat_messages(chat), context_wrapper)
    attrs = {}
    merge_trace_capture_attributes!(attrs, context_wrapper)
    attrs[ATTR_LANGFUSE_OBSERVATION_INPUT] = input if input.present?
    llm_span = @tracer.start_span(@llm_span_name, with_parent: parent_context(tracing), attributes: attrs)
    tracing[:last_llm_metadata] = span_metadata(
      span: llm_span,
      root_span: tracing[:root_span],
      parent_span: parent_span_for(tracing),
      kind: 'llm',
      name: @llm_span_name
    )
    set_trace_event_context!(context_wrapper, tracing[:last_llm_metadata])

    llm_span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, model) if model

    output = llm_output_text(message, context_wrapper)
    set_llm_response_attributes(llm_span, message, output)
    tracing[:last_agent_output] = output unless output.empty?

    llm_span.finish
  end

  def finish_dangling_spans(tracing)
    if tracing[:current_tool_span]
      tracing[:current_tool_span].finish
      tracing[:current_tool_span] = nil
    end

    finish_agent_span(tracing)
  end

  def set_run_output_attributes(root_span, result, context_wrapper)
    return unless result.respond_to?(:output)

    output_text = trace_output_payload(result.output, context_wrapper)
    return if output_text.empty?

    root_span.set_attribute(ATTR_LANGFUSE_TRACE_OUTPUT, output_text)
    root_span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, output_text)
  end

  def set_run_error_status(root_span, result)
    return unless result.respond_to?(:error)

    error = result.error
    return unless error

    root_span.record_exception(error)
    root_span.status = OpenTelemetry::Trace::Status.error(error.message)
  end

  def set_llm_response_attributes(span, response, output)
    span.set_attribute(ATTR_GEN_AI_USAGE_INPUT_TOKENS, response.input_tokens) if response.respond_to?(:input_tokens) && response.input_tokens
    span.set_attribute(ATTR_GEN_AI_USAGE_OUTPUT_TOKENS, response.output_tokens) if response.respond_to?(:output_tokens) && response.output_tokens
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, output) unless output.empty?
  end

  def llm_output_text(response, context_wrapper)
    if response.respond_to?(:content) && response.content
      text = trace_output_payload(response.content, context_wrapper)
      return text unless text.empty?
    end

    trace_output_payload(format_tool_calls(response), context_wrapper).to_s
  end

  def format_chat_messages(chat)
    return nil unless chat.respond_to?(:messages)

    messages = chat.messages
    return nil if messages.blank?

    messages[0...-1].map { |message| format_single_message(message) }.to_json
  end

  def format_single_message(message)
    text = serialize_output(message.content)
    text = append_tool_calls(message, text)
    { role: message.role.to_s, content: text }
  end

  def append_tool_calls(message, text)
    return text unless message.role == :assistant && message.respond_to?(:tool_calls) && message.tool_calls.present?

    calls = message.tool_calls.values.map { |tool_call| "#{tool_call.name}(#{serialize_output(tool_call.arguments)})" }.join(', ')
    text.empty? ? "Tool calls: #{calls}" : "#{text}\nTool calls: #{calls}"
  end

  def serialize_output(value)
    return serialize_multimodal_content(value) if multimodal_content?(value)

    value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
  end

  def format_tool_calls(response)
    return '' unless response.respond_to?(:tool_calls) && response.tool_calls.present?

    calls = response.tool_calls.values.map do |tool_call|
      "#{tool_call.name}(#{serialize_output(tool_call.arguments)})"
    end
    "Tool calls: #{calls.join(', ')}"
  end

  def start_agent_span(tracing, agent_name, context_wrapper)
    finish_agent_span(tracing)

    attrs = { 'agent.name' => agent_name }
    merge_trace_capture_attributes!(attrs, context_wrapper)
    input = tracing[:pending_llm_input]
    attrs[ATTR_LANGFUSE_OBSERVATION_INPUT] = input if input.present?

    agent_span = @tracer.start_span(
      format(@agent_span_name, agent_name),
      with_parent: tracing[:root_context],
      attributes: attrs
    )

    tracing[:current_agent_name] = agent_name
    tracing[:current_agent_span] = agent_span
    tracing[:current_agent_context] = OpenTelemetry::Trace.context_with_span(agent_span)
    tracing[:current_agent_metadata] = span_metadata(
      span: agent_span,
      root_span: tracing[:root_span],
      parent_span: tracing[:root_span],
      kind: 'agent',
      name: format(@agent_span_name, agent_name)
    )
    tracing[:last_agent_output] = nil
  end

  def finish_agent_span(tracing)
    return unless tracing[:current_agent_span]

    last_output = tracing[:last_agent_output]
    tracing[:current_agent_span].set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, last_output) if last_output.present?
    tracing[:last_agent_metadata] = tracing[:current_agent_metadata]
    tracing[:current_agent_span].finish
    tracing[:current_agent_name] = nil
    tracing[:current_agent_span] = nil
    tracing[:current_agent_context] = nil
    tracing[:current_agent_metadata] = nil
    tracing[:last_agent_output] = nil
  end

  def parent_context(tracing)
    tracing[:current_agent_context] || tracing[:root_context]
  end

  def parent_span_for(tracing)
    tracing[:current_agent_span] || tracing[:root_span]
  end

  def handoff_tool?(tool_name)
    tool_name.to_s.start_with?('handoff_to_')
  end

  def build_root_attributes(agent_name, input, context_wrapper)
    attributes = @span_attributes.dup
    session_id = context_wrapper&.context&.dig(:session_id)&.to_s
    attributes[ATTR_LANGFUSE_SESSION_ID] = session_id if session_id.present?
    merge_trace_capture_attributes!(attributes, context_wrapper)

    serialized_input = trace_input_payload(input, context_wrapper)
    if serialized_input.present?
      attributes[ATTR_LANGFUSE_TRACE_INPUT] = serialized_input
      attributes[ATTR_LANGFUSE_OBSERVATION_INPUT] = serialized_input
    end

    attributes['agent.name'] = agent_name

    if @attribute_provider
      dynamic_attributes = @attribute_provider.call(context_wrapper)
      attributes.merge!(dynamic_attributes) if dynamic_attributes.is_a?(Hash)
    end

    attributes
  end

  def multimodal_content?(value)
    value.respond_to?(:text) && value.respond_to?(:attachments)
  end

  def serialize_multimodal_content(content)
    parts = []
    parts << content.text if content.text.present?

    if content.attachments.present?
      urls = content.attachments.map { |attachment| attachment.respond_to?(:source) ? attachment.source.to_s : attachment.to_s }
      parts << "Attachments: #{urls.join(', ')}"
    end

    parts.join("\n")
  end

  def runtime_preferences(context_wrapper)
    context_wrapper&.context&.dig(:state, :captain_runtime)
  end

  def trace_input_payload(value, context_wrapper, prefer_context: false)
    precomputed_input = context_wrapper&.context&.dig(:captain_v2_trace_current_input)
    return precomputed_input if prefer_context && precomputed_input.present?

    Llm::TracePayloadPolicy.capture(
      serialize_output(value),
      direction: :input,
      preferences: runtime_preferences(context_wrapper)
    ).to_s
  end

  def trace_output_payload(value, context_wrapper)
    Llm::TracePayloadPolicy.capture(
      serialize_output(value),
      direction: :output,
      preferences: runtime_preferences(context_wrapper)
    ).to_s
  end

  def merge_trace_capture_attributes!(attributes, context_wrapper)
    attributes.merge!(
      Llm::TracePayloadPolicy.trace_attributes(
        preferences: runtime_preferences(context_wrapper)
      )
    )
  end

  def set_tool_result_attributes(span, result, output)
    normalized = Captain::ToolResult.normalize(result).with_indifferent_access
    span.set_attribute('tool.result.success', normalized[:success]) unless normalized[:success].nil?
    span.set_attribute('tool.result.retryable', normalized[:retryable]) unless normalized[:retryable].nil?
    span.set_attribute('tool.result.error', normalized[:error].to_s.truncate(500)) if normalized[:error].present?
    span.set_attribute('tool.result.size_bytes', output.to_s.bytesize) if output.present?
  end

  def set_trace_event_context!(context_wrapper, metadata)
    return unless context_wrapper&.context

    context_wrapper.context[TRACE_EVENT_CONTEXT_KEY] = metadata.to_h.stringify_keys
  end

  def span_metadata(span:, root_span:, kind:, name:, parent_span: nil)
    return {} unless span

    {
      trace_id: span.context.hex_trace_id,
      trace_name: @trace_name,
      root_span_id: root_span&.context&.hex_span_id || span.context.hex_span_id,
      span_id: span.context.hex_span_id,
      parent_span_id: parent_span&.context&.hex_span_id,
      span_kind: kind,
      span_name: name
    }.compact
  end
end
