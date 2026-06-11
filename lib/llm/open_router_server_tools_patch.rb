# frozen_string_literal: true

module Llm; end

module Llm::OpenRouterServerToolsPatch
  SERVER_TOOLS_PARAM = :openrouter_server_tools_payload
  OMIT_TEMPERATURE_PARAM = :openrouter_omit_temperature

  def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &block)
    normalized_params = params.respond_to?(:to_h) ? params.to_h.deep_dup : {}
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
end

RubyLLM::Providers::OpenRouter.prepend(Llm::OpenRouterServerToolsPatch) if defined?(RubyLLM::Providers::OpenRouter)
