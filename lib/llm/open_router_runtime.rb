# frozen_string_literal: true

class Llm::OpenRouterRuntime
  OPENROUTER_PROVIDER = 'openrouter'

  attr_reader :account

  def initialize(account: nil)
    @account = account
  end

  def chat(request)
    request = normalize_request(request)
    model = resolve_model(request)
    enforce_budget!(request, model)
    compiled = compiled_chat_request(request, model)
    runner = Llm::ChatRequestRunner.new(
      context: chat_context(request, model),
      chat: request.options[:chat],
      model: model,
      messages: request.messages,
      schema: request.schema,
      tools: request.tools,
      params: compiled.params,
      headers: compiled.headers,
      temperature: request.temperature,
      account: request_account(request),
      feature: request.feature_key,
      observability: runtime_observability(request, routing_metadata: compiled.metadata),
      content_builder: request.options[:content_builder],
      on_end_message: request.options[:on_end_message],
      on_tool_call: request.options[:on_tool_call],
      on_tool_result: request.options[:on_tool_result]
    )
    runner.call
  end

  def build_chat(request)
    request = normalize_request(request)
    model = resolve_model(request)
    compiled = compiled_chat_request(request, model)
    Llm::ChatClient.build(
      context: chat_context(request, model),
      chat: request.options[:chat],
      model: model,
      params: compiled.params,
      headers: compiled.headers,
      temperature: request.temperature,
      thinking: request.reasoning || request.options[:thinking],
      stream: request.stream,
      account: request_account(request),
      feature: request.feature_key,
      observability: runtime_observability(request, routing_metadata: compiled.metadata),
      routing_metadata: compiled.metadata
    )
  end

  def build_chat_legacy(**)
    Llm::ChatClient.build(**)
  end

  def ask(chat, content, model: nil, observability: nil)
    enriched_observability = observed_ask_observability(chat, observability)
    enforce_observed_ask_budget!(model: model, observability: enriched_observability)
    Llm::ChatClient.ask(chat, content, model: model, observability: enriched_observability, account: account)
  end

  def transcribe(request)
    request = normalize_request(request, feature: :audio_transcription)
    raise ArgumentError, 'input is required for OpenRouter transcription.' if request.input.blank?

    model = resolve_model(request)
    enforce_budget!(request, model)
    profile = routing_profile(request, model)
    headers = native_headers(request, profile)
    observe_native_request(request, model, 'transcription.complete', routing_metadata: native_routing_metadata(request, model, profile, headers)) do
      with_openrouter_retry(request, model) do
        Llm::OpenRouterTranscriptionClient.transcribe(
          request.input,
          model: model,
          api_key: api_key!(request),
          api_base: api_base(request),
          prompt: request.options[:prompt],
          language: request.options[:language],
          temperature: request.temperature.nil? ? 0.4 : request.temperature,
          provider: profile.provider_preferences,
          headers: headers.headers
        )
      end
    end
  end

  def embed(request)
    request = normalize_request(request, feature: :embedding)
    raise ArgumentError, 'input is required for OpenRouter embeddings.' if request.input.blank?

    model = resolve_model(request)
    enforce_budget!(request, model)
    profile = routing_profile(request, model)
    headers = native_headers(request, profile)
    observe_native_request(request, model, 'embedding.complete', routing_metadata: native_routing_metadata(request, model, profile, headers)) do
      with_openrouter_retry(request, model) do
        Llm::OpenRouterEmbeddingClient.embed(
          request.input,
          model: model,
          dimensions: request.options[:dimensions],
          input_type: request.options[:input_type],
          api_key: api_key!(request),
          api_base: api_base(request),
          provider: profile.provider_preferences,
          headers: headers.headers
        )
      end
    end
  end

  def rerank(request)
    request = normalize_request(request, feature: :knowledge_rerank)
    query = rerank_query(request)
    documents = rerank_documents(request)
    raise ArgumentError, 'query is required for OpenRouter rerank.' if query.blank?
    raise ArgumentError, 'documents are required for OpenRouter rerank.' if documents.blank?

    model = resolve_model(request)
    raise ArgumentError, 'model is required for OpenRouter rerank.' if model.blank?

    enforce_budget!(request, model)
    profile = routing_profile(request, model)
    headers = native_headers(request, profile)

    observe_native_request(request, model, 'rerank.complete', routing_metadata: native_routing_metadata(request, model, profile, headers)) do
      with_openrouter_retry(request, model) do
        Llm::OpenRouterRerankClient.rerank(
          query: query,
          documents: documents,
          model: model,
          top_n: request.options[:top_n],
          return_documents: request.options.fetch(:return_documents, true),
          api_key: api_key!(request),
          api_base: api_base(request),
          provider: profile.provider_preferences,
          headers: headers.headers
        )
      end
    end
  end

  def metadata(generation_id)
    Llm::OpenRouterGenerationClient.fetch(
      generation_id,
      api_key: api_key_for(account),
      api_base: api_base_for(account)
    )
  end

  def available_models(feature)
    profile = Llm::FeatureProfile.for(feature, account: account)
    Llm::Models.models_for(profile.config_feature_key, account: account, runtime_filtered: true)
  end

  def diagnose_model(model_id, feature, runtime_preferences: nil)
    profile = Llm::FeatureProfile.for(feature, account: account)
    Llm::OpenRouterCapabilityResolver.call(
      model_id: model_id,
      feature: profile.config_feature_key,
      account: account,
      runtime_preferences: runtime_preferences,
      runtime_filtered: true
    )
  end

  private

  def normalize_request(request, feature: nil)
    return request if request.is_a?(Llm::FeatureRequest)

    attributes = request.respond_to?(:to_h) ? request.to_h.symbolize_keys : {}
    attributes[:feature] ||= feature if feature.present?
    Llm::FeatureRequest.new(**attributes)
  end

  def request_account(request)
    request.account.presence || account
  end

  def resolve_model(request)
    return request.model if request.model.present?

    profile = request.profile
    Llm::Config.model_for(feature: profile.config_feature_key, account: request_account(request), fallback: nil)
  end

  def compiled_chat_request(request, model)
    Llm::EventBus.publish('request.compile', compile_observability_payload(request, model)) do |event_payload|
      compiled = Llm::OpenRouterRequestCompiler.call(
        request: request,
        model: model,
        account: request_account(request),
        base_params: request.options[:params] || {},
        stream: request.stream,
        schema: request.schema_required?,
        tools: request.requires_tools?,
        reasoning: request.reasoning_requested?
      )
      attach_compile_success!(event_payload, compiled)
      compiled
    rescue StandardError => e
      Llm::ObservabilityPayload.attach_error!(event_payload, e)
      raise
    end
  end

  def compile_observability_payload(request, model)
    runtime_observability(request).merge(
      model: model,
      requested_model: model,
      provider: OPENROUTER_PROVIDER,
      status: 'compiling'
    ).compact
  end

  def attach_compile_success!(event_payload, compiled)
    event_payload.merge!(compiled.metadata.to_h.stringify_keys)
    event_payload['status'] = 'success'
    event_payload['error'] = false
  end

  def observe_native_request(request, model, event_name, routing_metadata: nil)
    payload = native_observability_payload(request, model, routing_metadata: routing_metadata)

    instrument_native_request(event_name, payload) do |event_payload|
      response = yield
      attach_native_response!(event_payload, event_name, response)
      response
    rescue StandardError => e
      Llm::ObservabilityPayload.attach_error!(event_payload, e)
      raise
    end
  end

  def native_observability_payload(request, model, routing_metadata: nil)
    Llm::ObservabilityPayload.normalize(
      runtime_observability(request, routing_metadata: routing_metadata),
      model: model,
      runtime_mode: 'openrouter_runtime'
    )
  end

  def instrument_native_request(event_name, payload, &)
    if native_event_subscribers?(event_name)
      Llm::EventBus.publish(event_name, payload, &)
    else
      record_native_request(event_name, payload, &)
    end
  end

  def native_event_subscribers?(event_name)
    ActiveSupport::Notifications.notifier.listeners_for("llm.#{event_name}").any?
  end

  def record_native_request(event_name, payload)
    started_at = Time.current
    event_payload = payload.stringify_keys.merge('canonical_event_name' => "llm.#{event_name}")
    response = yield(event_payload)
    record_native_event(event_name, started_at, event_payload)
    response
  rescue StandardError
    record_native_event(event_name, started_at, event_payload) if event_payload.present?
    raise
  end

  def record_native_event(event_name, started_at, event_payload)
    Llm::Monitoring::EventRecorder.record_notification(
      event_name: "llm.#{event_name}",
      started_at: started_at,
      finished_at: Time.current,
      payload: event_payload
    )
  end

  def attach_native_response!(event_payload, event_name, response)
    case event_name
    when 'embedding.complete'
      Llm::ObservabilityPayload.attach_embedding_response!(event_payload, response)
    when 'rerank.complete'
      Llm::ObservabilityPayload.attach_rerank_response!(event_payload, response)
    when 'transcription.complete'
      Llm::ObservabilityPayload.attach_transcription_response!(event_payload, response)
    end
  end

  def with_openrouter_retry(request, model)
    policy = Llm::OpenRouterRetryPolicy.new(
      provider: OPENROUTER_PROVIDER,
      model: model,
      feature: request.feature_key,
      account: request_account(request),
      tools: request.tools,
      stream: request.stream
    )
    attempt = 0

    loop do
      attempt += 1
      response = yield
      decision = policy.retryable_response?(response, attempt: attempt)
      return response unless decision.retryable?

      publish_native_retry_event(request, model, decision, attempt)
    rescue StandardError => e
      decision = policy.retryable_error?(e, attempt: attempt)
      raise unless decision.retryable?

      publish_native_retry_event(request, model, decision, attempt, error: e)
    end
  end

  def publish_native_retry_event(request, model, decision, attempt, error: nil)
    payload = native_observability_payload(request, model, routing_metadata: native_routing_metadata(request, model)).merge(
      status: 'retrying',
      error: error.present?,
      reason: decision.reason,
      openrouter_error_category: decision.category,
      retry_after_seconds: decision.retry_after_seconds,
      attempt: attempt,
      max_attempts: decision.max_attempts,
      retry_count: attempt,
      provider: OPENROUTER_PROVIDER
    ).compact
    payload[:error_class] = error.class.name if error
    payload[:error_message] = Llm::ObservabilityPayload.sanitize_error_message(error) if error

    Llm::EventBus.publish('run.retry', payload)
  end

  def chat_context(request, model)
    return request.options[:context] if request.options.key?(:context)
    return if model.blank?

    Llm::Config.context(
      provider: OPENROUTER_PROVIDER,
      model: model,
      account: request_account(request),
      api_key: api_key_for(request_account(request)),
      api_base: api_base_for(request_account(request))
    )
  end

  def runtime_observability(request, routing_metadata: nil)
    request.observability.merge(
      provider: OPENROUTER_PROVIDER,
      feature: runtime_observability_feature(request),
      account_id: request_account(request)&.id,
      session_id: request.session_id,
      user_id: request.user_id,
      runtime_mode: 'openrouter_runtime'
    ).merge(openrouter_routing_metadata(routing_metadata)).compact
  end

  def runtime_observability_feature(request)
    request.observability[:feature].presence ||
      request.observability[:feature_name].presence ||
      request.feature.to_s.presence ||
      request.feature_key
  end

  def routing_profile(request, model)
    Llm::OpenRouterRoutingProfile.for(
      feature: request.feature_key,
      model: model,
      account: request_account(request),
      runtime_preferences: request.runtime_preferences,
      privacy_profile: request.privacy_profile
    )
  end

  def openrouter_routing_metadata(metadata)
    metadata.respond_to?(:to_h) ? metadata.to_h.symbolize_keys : {}
  rescue StandardError
    {}
  end

  def native_routing_metadata(request, model, profile = nil, headers = nil)
    profile ||= routing_profile(request, model)
    headers ||= native_headers(request, profile)
    provider = profile.provider_preferences
    feature_policy = request.openrouter_feature_policy
    {
      requested_model: model,
      models: profile.models,
      fallback_models: profile.fallback_models,
      routing_profile: routing_profile_name(profile, provider),
      openrouter_provider_order: Array(provider[:order]).presence,
      openrouter_provider_sort: provider_sort(provider),
      openrouter_allow_fallbacks: provider[:allow_fallbacks],
      openrouter_require_parameters: provider[:require_parameters],
      openrouter_data_collection: provider[:data_collection],
      openrouter_zdr: provider[:zdr],
      openrouter_service_tier: feature_policy.compiled_service_tier,
      openrouter_native_endpoint: profile.native_endpoint,
      openrouter_privacy_profile: feature_policy.privacy_profile,
      openrouter_guardrail_profile: feature_policy.guardrail_profile,
      openrouter_cache_policy: feature_policy.cache_policy,
      openrouter_plugin_policy: feature_policy.plugin_policy,
      openrouter_transform_policy: feature_policy.transform_policy,
      openrouter_budget_policy: feature_policy.budget_policy
    }.merge(headers.metadata).compact
  end

  def native_headers(request, profile)
    policy = request.openrouter_feature_policy
    Llm::OpenRouterHeaders.build(
      cache_policy: policy.cache_policy,
      provider_params: profile.provider_preferences,
      native_endpoint: profile.native_endpoint,
      cache_options: request.options,
      privacy_profile: policy.privacy_profile,
      trace_capture_allowed: policy.workspace_policy&.trace_capture_allowed?
    )
  end

  def routing_profile_name(profile, provider)
    profile.routing_policy[:strategy].presence ||
      provider_sort(provider).presence ||
      (provider[:order].present? ? 'ordered' : 'balanced')
  end

  def provider_sort(provider)
    sort = provider[:sort]
    return sort.to_h.with_indifferent_access[:by].to_s.presence if sort.respond_to?(:to_h)
    return sort.to_s.presence if sort.present?
  end

  def observed_ask_observability(chat, observability)
    routing_metadata = Llm::OpenRouterRequestPolicy.observability_metadata(chat)
    return observability if routing_metadata.blank?

    routing_metadata.merge(observability_hash(observability))
  end

  def enforce_budget!(request, model)
    Llm::BudgetEvaluator.evaluate!(request: request, model: model)
  end

  def enforce_observed_ask_budget!(model:, observability:)
    return if account.blank?

    feature = observability_feature(observability).presence || 'assistant'
    request = Llm::FeatureRequest.new(
      feature: feature,
      account: account,
      model: model,
      observability: observability.respond_to?(:to_h) ? observability.to_h : {},
      options: { estimated_cost: observability_estimated_cost(observability) }.compact
    )
    enforce_budget!(request, model)
  end

  def observability_feature(observability)
    return unless observability.respond_to?(:[])

    observability[:feature] || observability['feature'] || observability[:feature_name] || observability['feature_name']
  end

  def observability_estimated_cost(observability)
    return unless observability.respond_to?(:[])

    observability[:estimated_cost] || observability['estimated_cost'] || observability[:cost] || observability['cost']
  end

  def observability_hash(observability)
    return {} unless observability.respond_to?(:to_h)

    observability.to_h.symbolize_keys
  rescue StandardError
    {}
  end

  def rerank_query(request)
    rerank_input(request)[:query] || request.options[:query]
  end

  def rerank_documents(request)
    Array(rerank_input(request)[:documents].presence || request.options[:documents]).compact_blank
  end

  def rerank_input(request)
    return {} unless request.input.respond_to?(:to_h)

    request.input.to_h.with_indifferent_access
  end

  def api_key!(request)
    api_key = api_key_for(request_account(request))
    raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for runtime request.' if api_key.blank?

    api_key
  end

  def api_key_for(runtime_account)
    Llm::Config.api_key(OPENROUTER_PROVIDER, account: runtime_account)
  end

  def api_base(request)
    api_base_for(request_account(request))
  end

  def api_base_for(runtime_account)
    Llm::Config.api_base(OPENROUTER_PROVIDER, account: runtime_account)
  end
end
