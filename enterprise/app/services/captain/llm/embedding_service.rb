class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end
  class EmbeddingsUnavailableError < EmbeddingsError; end

  VECTOR_DIMENSIONS = Captain::KnowledgeSettings::VECTOR_DIMENSIONS
  OPENROUTER_EMBEDDINGS_UNAVAILABLE = 'OpenRouter embeddings are not configured.'.freeze

  def initialize(account_id: nil)
    Llm::Config.initialize!
    @account_id = account_id
    @account = Account.find_by(id: account_id) if account_id.present?
    @embedding_model = self.class.embedding_model(account: @account)
  end

  def self.embedding_model(account: nil)
    configured_embedding_model.presence || Llm::Config.model_for(feature: 'help_center_search', account: account, fallback: nil)
  end

  def self.configured_embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence
  end

  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    raise embeddings_unavailable_error if model.blank?

    provider = Llm::Config.provider_for_model(model, account: @account)
    observability = instrumentation_params(content, model, provider)
    instrument_embedding_call(observability) do
      embedding_for_provider(content, model, provider, observability)
    end
  rescue RubyLLM::Error, RubyLLM::ConfigurationError => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def instrumentation_params(content, model, provider = nil)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      provider: provider || Llm::Config.provider_for_model(model, account: @account),
      input: content,
      feature_name: 'embedding',
      account_id: @account_id
    }
  end

  def embedding_for_provider(content, model, provider, observability)
    return openrouter_embedding(content, model) if provider == 'openrouter'

    Llm::Config.with_api_key(
      Llm::Config.api_key(provider, account: @account),
      api_base: Llm::Config.api_base(provider, account: @account),
      provider: provider,
      model: model,
      account: @account
    ) do |context|
      Llm::ApiClient.embed(
        content,
        context: context,
        model: model,
        dimensions: embedding_dimensions_for(model),
        observability: observability.merge(runtime_mode: 'captain_embedding')
      ).vectors
    end
  end

  def openrouter_embedding(content, model)
    api_key = Llm::Config.api_key('openrouter', account: @account)
    raise embeddings_unavailable_error if api_key.blank?

    result = Llm::OpenRouterEmbeddingClient.embed(
      content,
      model: model,
      dimensions: VECTOR_DIMENSIONS,
      api_key: api_key,
      api_base: Llm::Config.api_base('openrouter', account: @account)
    )
    vector = result.vectors.first
    raise EmbeddingsError, 'OpenRouter embedding response did not include a vector.' unless vector.is_a?(Array)

    vector
  end

  def embedding_dimensions_for(model)
    return unless model.to_s.match?(%r{(^|/)text-embedding-3-})

    VECTOR_DIMENSIONS
  end

  def embeddings_unavailable_error
    EmbeddingsUnavailableError.new(OPENROUTER_EMBEDDINGS_UNAVAILABLE)
  end
end
