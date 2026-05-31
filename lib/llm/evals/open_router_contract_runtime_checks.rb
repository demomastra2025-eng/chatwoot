# frozen_string_literal: true

module Llm::Evals::OpenRouterContractRuntimeChecks
  include Llm::Evals::OpenRouterContractSupport

  private

  def openrouter_tool_calling_contract
    compiled = compile_contract_request(
      feature: :editor,
      tools: true,
      base_params: { provider: { sort: { by: 'price' } } }
    )
    provider = compiled.params[:provider].to_h
    failures = []
    failures << 'provider.require_parameters missing for tool flow' unless provider[:require_parameters] == true
    failures << 'provider.sort must be removed for tool flow' if provider.key?(:sort) || provider.key?('sort')

    { provider: provider, expected: { require_parameters: true, no_price_sort: true }, failures: failures }
  end

  def openrouter_structured_output_contract
    compiled = compile_contract_request(feature: :captain_agent, schema: true, base_params: { plugins: [{ id: 'web' }] })
    streaming = compile_contract_request(feature: :captain_agent, schema: true, stream: true, base_params: { plugins: [{ id: 'web' }] })
    failures = structured_output_failures(compiled, streaming)

    {
      provider: compiled.params[:provider],
      plugins: plugin_ids(compiled.params[:plugins]),
      streaming_plugins: plugin_ids(streaming.params[:plugins]),
      expected: { require_parameters: true, response_healing: true, streaming_response_healing: false },
      failures: failures
    }
  end

  def openrouter_plugin_policy_contract
    ids = plugin_ids(plugin_policy_compiled_request.params[:plugins])

    {
      plugins: ids,
      expected: { allowed: [RESPONSE_HEALING_PLUGIN_ID, 'context-compression'], denied: ['web', 'openrouter:web-search', 'apply-patch'] },
      failures: plugin_policy_failures(ids)
    }
  end

  def openrouter_reasoning_contract
    request = ContractRequest.new(
      feature_key: 'captain_agent',
      reasoning_required: true,
      reasoning: { effort: 'low' }
    )
    compiled = Llm::OpenRouterRequestCompiler.call(request: request, model: 'openai/gpt-5.4-mini')
    failures = []
    failures << 'reasoning params missing' unless compiled.params[:reasoning] == { effort: 'low' }
    failures << 'provider.require_parameters missing for reasoning' unless compiled.params.dig(:provider, :require_parameters) == true

    {
      reasoning: compiled.params[:reasoning],
      provider: compiled.params[:provider],
      expected: { reasoning: { effort: 'low' }, require_parameters: true },
      failures: failures
    }
  end

  def openrouter_feature_request_contract
    account = ContractAccount.new(id: 42, captain_preferences: {})
    image_request = Llm::FeatureRequest.new(feature: :image_recognition, account: account, attachments: ['https://example.com/a.png'])
    audio_request = Llm::FeatureRequest.new(feature: :audio_transcription, account: account, input: '/tmp/message.ogg')
    mutating_request = mutating_feature_request(account)
    failures = feature_request_failures(image_request, audio_request, mutating_request)

    {
      image: { multimodal: image_request.multimodal?, image: image_request.image? },
      audio: { multimodal: audio_request.multimodal?, audio: audio_request.audio? },
      mutating_parallel_tool_calls: mutating_request.parallel_tool_calls,
      expected: { image_multimodal: true, audio_multimodal: true, mutating_parallel_tool_calls: false },
      failures: failures
    }
  end

  def openrouter_prompt_cache_contract
    account = ContractAccount.new(id: 42, captain_preferences: {})
    conversation = ContractConversation.new(id: 5, display_id: 99)
    request = Llm::FeatureRequest.new(feature: :captain_agent, account: account, conversation: conversation)
    compiled = Llm::OpenRouterRequestCompiler.call(request: request, model: 'openai/gpt-5.4-mini', account: account)
    failures = []
    failures << 'session cache key missing account/conversation scope' unless request.session_cache_key == 'llm:captain_agent:42:42_99'
    failures << 'compiler did not pass session_id to OpenRouter params' unless compiled.params[:session_id] == request.session_cache_key

    {
      session_id: request.session_id,
      session_cache_key: request.session_cache_key,
      compiled_session_id: compiled.params[:session_id],
      expected: { session_cache_key: 'llm:captain_agent:42:42_99' },
      failures: failures
    }
  end

  def structured_output_failures(compiled, streaming)
    failures = []
    healing_plugin = RESPONSE_HEALING_PLUGIN_ID
    failures << 'provider.require_parameters missing for structured output' unless compiled.params.dig(:provider, :require_parameters) == true
    failures << 'response-healing plugin missing' unless plugin_ids(compiled.params[:plugins]).include?(healing_plugin)
    failures << 'response-healing plugin must not be added for streaming' if plugin_ids(streaming.params[:plugins]).include?(healing_plugin)
    failures
  end

  def plugin_policy_compiled_request
    compile_contract_request(
      feature: :captain_agent,
      schema: true,
      runtime_preferences: { openrouter_allowed_plugins: ['context_compression', 'openrouter:web_search', 'apply_patch'] },
      base_params: { plugins: plugin_policy_probe_plugins }
    )
  end

  def plugin_policy_probe_plugins
    [
      { id: 'web' },
      { id: 'context_compression' },
      { id: 'openrouter:web_search' },
      { id: 'apply_patch' },
      { id: RESPONSE_HEALING_PLUGIN_ID }
    ]
  end

  def plugin_policy_failures(ids)
    failures = []
    failures << 'response-healing plugin missing from structured policy' unless ids.include?(RESPONSE_HEALING_PLUGIN_ID)
    failures << 'policy-allowed context compression plugin missing' unless ids.include?('context-compression')
    failures << 'caller-supplied web plugin must be filtered' if ids.include?('web')
    failures << 'OpenRouter web search plugin must stay denied by product policy' if ids.include?('openrouter:web-search')
    failures << 'OpenRouter apply_patch plugin must stay denied by product policy' if ids.include?('apply-patch')
    failures
  end

  def mutating_feature_request(account)
    Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      tools: [ContractTool.new(definition: { id: 'update_deal', risk_level: 'high', idempotent: false })],
      parallel_tool_calls: true
    )
  end

  def feature_request_failures(image_request, audio_request, mutating_request)
    failures = []
    failures << 'image request must be multimodal image' unless image_request.multimodal? && image_request.image?
    failures << 'audio request must be multimodal audio' unless audio_request.multimodal? && audio_request.audio?
    failures << 'mutating tool flow must disable parallel tool calls' unless mutating_request.parallel_tool_calls == false
    failures
  end
end
