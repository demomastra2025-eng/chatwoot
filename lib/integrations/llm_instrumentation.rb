# frozen_string_literal: true

require 'opentelemetry_config'

module Integrations::LlmInstrumentation
  include Integrations::LlmInstrumentationConstants
  include Integrations::LlmInstrumentationHelpers
  include Integrations::LlmInstrumentationSpans

  def instrument_llm_call(params)
    return yield unless ChatwootApp.otel_enabled?

    result = nil
    executed = false
    tracer.in_span(params[:span_name]) do |span|
      setup_span_attributes(span, params)
      result = yield
      executed = true
      record_completion(span, result, params)
      result
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: resolve_account(params)).capture_exception
    executed ? result : yield
  end

  def instrument_agent_session(params)
    return yield unless ChatwootApp.otel_enabled?

    result = nil
    executed = false
    tracer.in_span(params[:span_name]) do |span|
      set_metadata_attributes(span, params)

      # By default, the input and output of a trace are set from the root observation
      input = capture_trace_input(params[:messages], params)
      if input.present?
        span.set_attribute(ATTR_LANGFUSE_TRACE_INPUT, input)
        span.set_attribute(ATTR_LANGFUSE_OBSERVATION_INPUT, input)
      end
      result = yield
      executed = true
      output = capture_trace_output(result, params)
      if output.present?
        span.set_attribute(ATTR_LANGFUSE_TRACE_OUTPUT, output)
        span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, output)
      end
      set_error_attributes(span, result) if result.is_a?(Hash)
      result
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: resolve_account(params)).capture_exception
    executed ? result : yield
  end

  def instrument_tool_call(tool_name, arguments, params = {})
    # There is no error handling because tools can fail and LLMs should be
    # aware of those failures and factor them into their response.
    return yield unless ChatwootApp.otel_enabled?

    tracer.in_span(format(TOOL_SPAN_NAME, tool_name)) do |span|
      span.set_attribute(ATTR_LANGFUSE_OBSERVATION_TYPE, 'tool')
      trace_capture_attributes(params).each do |key, value|
        span.set_attribute(key, value)
      end
      set_metadata_attributes(span, params) if params.present?
      input = capture_trace_input(arguments, params)
      span.set_attribute(ATTR_LANGFUSE_OBSERVATION_INPUT, input) if input.present?
      result = yield
      output = capture_trace_output(result, params)
      span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, output) if output.present?
      set_tool_result_attributes(span, result, output)
      set_error_attributes(span, result) if result.is_a?(Hash)
      result
    end
  end

  def instrument_embedding_call(params)
    return yield unless ChatwootApp.otel_enabled?

    instrument_with_span(params[:span_name] || 'llm.embedding', params) do |span, track_result|
      set_embedding_span_attributes(span, params)
      result = yield
      track_result.call(result)
      set_embedding_result_attributes(span, result)
      result
    end
  end

  def instrument_audio_transcription(params)
    return yield unless ChatwootApp.otel_enabled?

    instrument_with_span(params[:span_name] || 'llm.audio.transcription', params) do |span, track_result|
      set_audio_transcription_span_attributes(span, params)
      result = yield
      track_result.call(result)
      set_transcription_result_attributes(span, result, params)
      result
    end
  end

  def instrument_moderation_call(params)
    return yield unless ChatwootApp.otel_enabled?

    instrument_with_span(params[:span_name] || 'llm.moderation', params) do |span, track_result|
      set_moderation_span_attributes(span, params)
      result = yield
      track_result.call(result)
      set_moderation_result_attributes(span, result, params)
      result
    end
  end

  def instrument_with_span(span_name, params, &)
    result = nil
    executed = false
    tracer.in_span(span_name) do |span|
      track_result = lambda do |r|
        executed = true
        result = r
      end
      yield(span, track_result)
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: resolve_account(params)).capture_exception
    raise unless executed

    result
  end

  private

  def resolve_account(params)
    return params[:account] if params[:account].is_a?(Account)
    return Account.find_by(id: params[:account_id]) if params[:account_id].present?

    nil
  end

  def set_tool_result_attributes(span, result, serialized_output)
    return unless defined?(Captain::ToolResult)

    normalized = Captain::ToolResult.normalize(result).with_indifferent_access
    span.set_attribute('tool.result.success', normalized[:success]) unless normalized[:success].nil?
    span.set_attribute('tool.result.retryable', normalized[:retryable]) unless normalized[:retryable].nil?
    span.set_attribute('tool.result.error', normalized[:error].to_s.truncate(500)) if normalized[:error].present?
    span.set_attribute('tool.result.size_bytes', serialized_output.to_s.bytesize) if serialized_output.present?
  rescue StandardError
    nil
  end
end
