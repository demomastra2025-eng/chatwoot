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

  def openrouter_structured_output_recovery_contract
    valid = structured_output_valid_json_result
    repaired = structured_output_repaired_json_result
    fallback = structured_output_plain_text_fallback_result
    hard_failure = structured_output_hard_failure_result
    failures = []
    failures << 'valid Captain JSON did not normalize with defaults' unless valid[:status] == 'pass'
    failures << 'invalid structured JSON did not repair to valid JSON' unless repaired[:status] == 'pass'
    failures << 'safe final plain text did not wrap into Captain response after attempts were exhausted' unless fallback[:status] == 'pass'
    failures << 'unsafe/unclosed reasoning text must fail hard' unless hard_failure[:status] == 'fail'

    {
      valid: valid,
      repaired: repaired,
      plain_text_fallback: fallback,
      hard_failure: hard_failure,
      expected: {
        valid_json: 'pass',
        repaired_json: 'pass',
        plain_text_fallback: 'pass',
        hard_failure: 'fail'
      },
      failures: failures
    }
  end

  def openrouter_plugin_policy_contract
    ids = plugin_ids(plugin_policy_compiled_request.params[:plugins])

    {
      plugins: ids,
      expected: {
        allowed: [RESPONSE_HEALING_PLUGIN_ID],
        policy_controlled: ['context-compression'],
        denied: ['web', 'openrouter:web-search', 'apply-patch']
      },
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

  def openrouter_context_compression_contract
    compiled = nil
    Llm::Evals::MethodStub.with(
      Llm::Models,
      :model_config,
      ->(_model, account: nil) { { 'context_length' => 100 } }
    ) do
      compiled = compile_contract_request(
        feature: :captain_agent,
        model: 'openai/context-contract',
        schema: true,
        runtime_preferences: { transform_policy: 'overflow_only' },
        messages: [
          { role: 'system', content: 'Stable CRM facts must be preserved.' },
          { role: 'user', content: 'x' * 360 }
        ]
      )
    end
    plugin_ids = plugin_ids(compiled.params[:plugins])
    metadata = compiled.metadata
    failures = []
    failures << 'context compression plugin missing for overflow context' unless plugin_ids.include?('context-compression')
    failures << 'context transform status must be applied' unless metadata[:openrouter_context_transform_status] == 'applied'
    failures << 'estimated tokens must be recorded' unless metadata[:openrouter_context_estimated_tokens].to_i.positive?

    {
      plugins: plugin_ids,
      metadata: metadata.slice(:openrouter_context_transform_status, :openrouter_context_estimated_tokens, :openrouter_context_limit),
      expected: { plugin: 'context-compression', status: 'applied' },
      failures: failures
    }
  end

  def openrouter_tool_result_requires_final_answer_contract
    recovered = replay_tool_result_recovered
    missing = replay_tool_result_missing_final_answer
    failures = []
    failures << 'recovered tool-result replay must pass' unless recovered[:status] == 'pass'
    failures << 'missing final answer replay must fail' unless missing[:status] == 'fail'
    unless Array(missing[:failures]).include?('assistant response missing after last user message')
      failures << 'missing final answer failure reason was not explicit'
    end

    {
      recovered_status: recovered[:status],
      missing_status: missing[:status],
      missing_failures: missing[:failures],
      expected: { recovered: 'pass', missing: 'fail' },
      failures: failures
    }
  end

  def openrouter_zero_completion_recovery_contract
    result = replay_case(
      id: 'openrouter.zero_completion_recovered_mutating_tool',
      messages: [{ role: 'user', content: 'Удвой сумму сделки Хлопок.' }],
      events: [
        {
          event_name: 'llm.tool.complete',
          tool_name: 'update_deal',
          mutation: true,
          resource_type: 'deal',
          resource_id: 'deal-1',
          payload: { result: { amount: 180_000 } }
        },
        {
          event_name: 'llm.zero_completion.recovered',
          payload: { recovery_kind: 'finalization_only_retry', completed_tool_names: ['update_deal'] }
        },
        {
          event_name: 'llm.run.complete',
          payload: { response: 'Удвоил сумму сделки Хлопок до 180000 KZT.' }
        }
      ],
      expected: {
        require_event_names: ['llm.zero_completion.recovered'],
        require_tools: ['update_deal'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'update_deal', fragment: '180000' }],
        forbid_duplicate_mutations: true
      }
    )
    failures = []
    failures << 'zero-completion recovered replay must pass without duplicate mutation' unless result[:status] == 'pass'

    {
      replay_status: result[:status],
      duplicate_mutations: result.dig(:actual, :duplicate_mutations),
      expected: { replay_status: 'pass', duplicate_mutations: [] },
      failures: failures
    }
  end

  def openrouter_fallback_model_contract
    compiled = compile_contract_request(feature: :captain_agent, model: 'moonshotai/kimi-k2.6')
    failures = []
    failures << 'fallback models must be compiled for Captain agent' if compiled.metadata[:fallback_models].blank?
    failures << 'fallbacks must be allowed for default non-ZDR routing' unless compiled.metadata[:openrouter_allow_fallbacks] == true

    {
      models: compiled.models,
      fallback_models: compiled.metadata[:fallback_models],
      allow_fallbacks: compiled.metadata[:openrouter_allow_fallbacks],
      expected: { fallback_models_present: true, allow_fallbacks: true },
      failures: failures
    }
  end

  def openrouter_native_reasoning_trace_contract
    extracted = Captain::Runtime::MessageExtractor.extract_messages(
      reasoning_contract_chat,
      ContractAgent.new('assistant_agent')
    ).first
    absent = replay_case(
      id: 'openrouter.reasoning_absent_no_fake_block',
      messages: [
        { role: 'user', content: 'Что сделали?' },
        { role: 'assistant', content: 'Сделка обновлена.' }
      ],
      expected: {
        require_assistant_response_after_last_user: true,
        forbid_answer_fragments: ['Модель не передала отдельное обоснование', 'Model did not provide reasoning']
      }
    )
    failures = []
    failures << 'native reasoning payload missing' if extracted[:native_reasoning].blank?
    failures << 'reasoning details missing' if extracted[:native_reasoning]&.dig(:details).blank?
    failures << 'reasoning tokens missing' unless extracted[:native_reasoning]&.dig(:tokens) == 42
    failures << 'absent reasoning replay must not require or invent fake reasoning text' unless absent[:status] == 'pass'

    {
      native_reasoning: extracted[:native_reasoning],
      absent_reasoning_status: absent[:status],
      expected: { source: 'openrouter', tokens: 42, absent_status: 'pass' },
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

  def structured_output_valid_json_result
    response = ContractStructuredResponse.new('{"response":"Done","reasoning":"Checked the result."}')
    chat = structured_output_contract_chat([response])
    Llm::StructuredOutputPolicy.execute(chat: chat, max_attempts: 1) { chat.ask('Hello') }

    {
      status: response.content['artifact_ids'] == [] && response.content['handoff_message'] == '' ? 'pass' : 'fail',
      response: response.content
    }
  rescue StandardError => e
    { status: 'error', error: "#{e.class.name}: #{e.message}" }
  end

  def structured_output_repaired_json_result
    response_one = ContractStructuredResponse.new('{"unexpected":"field"}')
    response_two = ContractStructuredResponse.new('{"response":"Done","reasoning":"Repaired into the required schema."}')
    chat = structured_output_contract_chat([response_one, response_two])
    result = Llm::StructuredOutputPolicy.execute(chat: chat) { chat.ask('Hello') }

    {
      status: result.content['response'] == 'Done' && chat.messages == [response_two] && chat.instructions.size == 1 ? 'pass' : 'fail',
      response: result.content,
      repair_instruction_count: chat.instructions.size
    }
  rescue StandardError => e
    { status: 'error', error: "#{e.class.name}: #{e.message}" }
  end

  def structured_output_plain_text_fallback_result
    response = ContractStructuredResponse.new("<think>internal scratchpad</think>\nГотово, обновил сделку.")
    chat = structured_output_contract_chat([response])
    result = Llm::StructuredOutputPolicy.execute(chat: chat, max_attempts: 1) { chat.ask('Hello') }

    {
      status: result.content['response'] == 'Готово, обновил сделку.' ? 'pass' : 'fail',
      response: result.content
    }
  rescue StandardError => e
    { status: 'error', error: "#{e.class.name}: #{e.message}" }
  end

  def structured_output_hard_failure_result
    response = ContractStructuredResponse.new("<think>internal scratchpad\nГотово, обновил сделку.")
    chat = structured_output_contract_chat([response])
    Llm::StructuredOutputPolicy.execute(chat: chat, max_attempts: 1) { chat.ask('Hello') }

    { status: 'pass', response: response.content }
  rescue Llm::StructuredOutputPolicy::InvalidStructuredOutputError => e
    { status: 'fail', error: e.message }
  rescue StandardError => e
    { status: 'error', error: "#{e.class.name}: #{e.message}" }
  end

  def structured_output_contract_chat(responses)
    ContractStructuredChat.new(
      responses: responses,
      model: ContractOpenRouterModel.new('moonshotai/kimi-k2.6', 'openrouter')
    ).tap do |chat|
      Llm::StructuredOutputPolicy.bind!(chat: chat, schema: Captain::ResponseSchema)
    end
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
    failures << 'caller-supplied context compression must be filtered unless overflow policy enables it' if ids.include?('context-compression')
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

  def replay_tool_result_recovered
    replay_case(
      id: 'openrouter.tool_result_final_answer_recovered',
      messages: [{ role: 'user', content: 'Найди сумму сделки.' }],
      events: [
        {
          event_name: 'llm.tool.complete',
          tool_name: 'search_deals',
          payload: { result: { amount: 125_000 } }
        },
        {
          event_name: 'llm.run.complete',
          payload: { response: 'Сумма сделки 125000 KZT.' }
        }
      ],
      expected: {
        require_tools: ['search_deals'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'search_deals', fragment: '125000' }]
      }
    )
  end

  def replay_tool_result_missing_final_answer
    replay_case(
      id: 'openrouter.tool_result_missing_final_answer',
      messages: [{ role: 'user', content: 'Найди сумму сделки.' }],
      events: [
        {
          event_name: 'llm.tool.complete',
          tool_name: 'search_deals',
          payload: { result: { amount: 125_000 } }
        }
      ],
      expected: {
        require_tools: ['search_deals'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'search_deals', fragment: '125000' }]
      }
    )
  end

  def replay_case(**attributes)
    Llm::Evals::Scenario::Replay.new(**attributes).call.to_case_result
  end

  ContractAgent = Struct.new(:name)
  ContractMessage = Struct.new(:role, :content, :reasoning, :reasoning_details, :reasoning_tokens, keyword_init: true) do
    def tool_call? = false
    def tool_calls = {}
  end
  ContractChat = Struct.new(:messages)
  ContractOpenRouterModel = Struct.new(:id, :provider)
  ContractStructuredResponse = Struct.new(:content) do
    def tool_call? = false
  end
  ContractStructuredChat = Struct.new(:responses, :model, keyword_init: true) do
    attr_reader :messages, :instructions, :params

    def initialize(**attributes)
      super
      @messages = []
      @instructions = []
      @params = {}
    end

    def with_schema(_schema)
      self
    end

    def with_params(**params)
      @params = params
      self
    end

    def with_instructions(value, append: false, replace: nil)
      @instructions << { value: value, append: append, replace: replace }
      self
    end

    def ask(_content)
      response = responses.shift
      @messages << response
      response
    end
  end

  def reasoning_contract_chat
    ContractChat.new(
      [
        ContractMessage.new(
          role: :assistant,
          content: 'Ответ готов.',
          reasoning: 'Checked CRM state.',
          reasoning_details: [{ type: 'summary', text: 'Checked CRM state.' }],
          reasoning_tokens: 42
        )
      ]
    )
  end
end
