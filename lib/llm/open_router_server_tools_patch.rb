# frozen_string_literal: true

module Llm; end

module Llm::OpenRouterServerToolsPatch
  SERVER_TOOLS_PARAM = :openrouter_server_tools_payload
  OMIT_TEMPERATURE_PARAM = :openrouter_omit_temperature
  STREAM_STACK_KEY = :onelink_openrouter_stream_meta_stack
  MESSAGE_STOP_INFO_IVAR = :@onelink_provider_stop_info

  def self.provider_stop_info(message)
    return {} unless message.instance_variable_defined?(MESSAGE_STOP_INFO_IVAR)

    message.instance_variable_get(MESSAGE_STOP_INFO_IVAR) || {}
  end

  def self.attach_stop_info!(message, finish_reasons: [], refusal: nil)
    return message unless message

    reasons = Array(finish_reasons).filter_map { |item| item.to_s.strip.downcase.presence }.uniq
    refusal_text = refusal.is_a?(String) ? refusal.strip.presence : nil
    return message if reasons.empty? && refusal_text.nil?

    message.instance_variable_set(MESSAGE_STOP_INFO_IVAR, { finish_reasons: reasons, refusal: refusal_text }.compact)
    message
  end

  def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &block)
    normalized_params = params.respond_to?(:to_h) ? params.to_h.deep_dup : {}
    if disable_reasoning_with_flag?(model, thinking)
      normalized_params.except!(:reasoning, 'reasoning', :reasoning_effort, 'reasoning_effort')
      normalized_params[:reasoning] = { enabled: false }
      thinking = nil
    end
    server_tools = Array(normalized_params.delete(SERVER_TOOLS_PARAM) || normalized_params.delete(SERVER_TOOLS_PARAM.to_s)).compact_blank
    omit_temperature = normalized_params.delete(OMIT_TEMPERATURE_PARAM) || normalized_params.delete(OMIT_TEMPERATURE_PARAM.to_s)
    normalized_temperature = omit_temperature ? nil : maybe_normalize_temperature(temperature, model)
    if server_tools.blank?
      return super(
        messages,
        tools: tools,
        temperature: normalized_temperature,
        model: model,
        params: normalized_params,
        headers: headers,
        schema: schema,
        thinking: thinking,
        tool_prefs: tool_prefs,
        &block
      )
    end

    payload = render_payload(
      messages,
      tools: tools,
      tool_prefs: tool_prefs,
      temperature: normalized_temperature,
      model: model,
      stream: block.present?,
      schema: schema,
      thinking: thinking
    )
    payload[:tools] = Array(payload[:tools]) + server_tools
    payload = RubyLLM::Utils.deep_merge(payload, normalized_params)

    if block
      stream_response @connection, payload, headers, &block
    else
      sync_response @connection, payload, headers
    end
  end

  def stream_response(connection, payload, additional_headers = {}, &)
    stack = (Thread.current[STREAM_STACK_KEY] ||= [])
    meta = { finish_reasons: [], refusal: +'' }
    stack.push(meta)
    message = super
    Llm::OpenRouterServerToolsPatch.attach_stop_info!(message, finish_reasons: meta[:finish_reasons], refusal: meta[:refusal])
  ensure
    stack&.pop
    Thread.current[STREAM_STACK_KEY] = nil if stack&.empty?
  end

  def build_chunk(data)
    capture_stream_stop_info!(data)
    super
  end

  def parse_completion_response(response)
    message = super
    attach_sync_stop_info!(message, response)
  end

  private

  def capture_stream_stop_info!(data)
    meta = Thread.current[STREAM_STACK_KEY]&.last
    choice = data.is_a?(Hash) ? Array(data['choices']).first : nil
    return unless meta && choice.is_a?(Hash)

    meta[:finish_reasons].concat([choice['finish_reason'], choice['native_finish_reason']].compact)
    refusal_piece = choice.dig('delta', 'refusal')
    meta[:refusal] << refusal_piece if refusal_piece.is_a?(String)
  end

  def attach_sync_stop_info!(message, response)
    body = response.respond_to?(:body) ? response.body : nil
    body = JSON.parse(body) if body.is_a?(String)
    choice = body.is_a?(Hash) ? Array(body['choices']).first : nil
    return message unless message && choice.is_a?(Hash)

    Llm::OpenRouterServerToolsPatch.attach_stop_info!(
      message, finish_reasons: [choice['finish_reason'], choice['native_finish_reason']], refusal: choice.dig('message', 'refusal')
    )
  rescue JSON::ParserError
    message
  end

  def disable_reasoning_with_flag?(model, thinking)
    effort = thinking.respond_to?(:effort) ? thinking.effort : thinking.to_h[:effort] || thinking.to_h['effort']
    return false unless effort.to_s == 'none'

    model_id = model.respond_to?(:id) ? model.id : model
    Llm::ModelParameters.for(model_id).disabled_reasoning_uses_flag?
  end
end

RubyLLM::Providers::OpenRouter.prepend(Llm::OpenRouterServerToolsPatch) if defined?(RubyLLM::Providers::OpenRouter)
