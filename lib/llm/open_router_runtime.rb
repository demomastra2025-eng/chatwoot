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
      temperature: request.options[:temperature],
      account: request_account(request),
      feature: request.feature_key,
      observability: runtime_observability(request),
      content_builder: request.options[:content_builder],
      on_end_message: request.options[:on_end_message],
      on_tool_call: request.options[:on_tool_call],
      on_tool_result: request.options[:on_tool_result]
    )
    runner.call
  end

  def transcribe(request)
    request = normalize_request(request, feature: :audio_transcription)
    raise ArgumentError, 'input is required for OpenRouter transcription.' if request.input.blank?

    model = resolve_model(request)
    observe_native_request(request, model, 'transcription.complete') do
      Llm::OpenRouterTranscriptionClient.transcribe(
        request.input,
        model: model,
        api_key: api_key!(request),
        api_base: api_base(request),
        language: request.options[:language],
        temperature: request.options.fetch(:temperature, 0.4),
        provider: routing_profile(request, model).provider_preferences
      )
    end
  end

  def embed(request)
    request = normalize_request(request, feature: :embedding)
    raise ArgumentError, 'input is required for OpenRouter embeddings.' if request.input.blank?

    model = resolve_model(request)
    observe_native_request(request, model, 'embedding.complete') do
      Llm::OpenRouterEmbeddingClient.embed(
        request.input,
        model: model,
        dimensions: request.options[:dimensions],
        api_key: api_key!(request),
        api_base: api_base(request),
        provider: routing_profile(request, model).provider_preferences
      )
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

    Llm::OpenRouterRerankClient.rerank(
      query: query,
      documents: documents,
      model: model,
      top_n: request.options[:top_n],
      return_documents: request.options.fetch(:return_documents, true),
      api_key: api_key!(request),
      api_base: api_base(request),
      provider: routing_profile(request, model).provider_preferences
    )
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
    Llm::OpenRouterRequestCompiler.call(
      request: request,
      model: model,
      account: request_account(request),
      base_params: request.options[:params] || {},
      stream: request.options[:stream],
      schema: request.requires_schema?,
      tools: request.requires_tools?,
      reasoning: request.reasoning?
    )
  end

  def observe_native_request(request, model, event_name)
    payload = native_observability_payload(request, model)
    return yield if payload.blank?

    Llm::EventBus.publish(event_name, payload) do |event_payload|
      response = yield
      attach_native_response!(event_payload, event_name, response)
      response
    rescue StandardError => e
      Llm::ObservabilityPayload.attach_error!(event_payload, e)
      raise
    end
  end

  def native_observability_payload(request, model)
    return {} if request.observability.blank?

    Llm::ObservabilityPayload.normalize(
      runtime_observability(request),
      model: model,
      runtime_mode: 'openrouter_runtime'
    )
  end

  def attach_native_response!(event_payload, event_name, response)
    case event_name
    when 'embedding.complete'
      Llm::ObservabilityPayload.attach_embedding_response!(event_payload, response)
    when 'transcription.complete'
      Llm::ObservabilityPayload.attach_transcription_response!(event_payload, response)
    end
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

  def runtime_observability(request)
    request.observability.merge(
      provider: OPENROUTER_PROVIDER,
      feature: request.feature_key,
      runtime_mode: 'openrouter_runtime'
    )
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
