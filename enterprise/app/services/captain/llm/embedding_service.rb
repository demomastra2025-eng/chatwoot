class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end
  class EmbeddingsUnavailableError < EmbeddingsError; end

  VECTOR_DIMENSIONS = Captain::KnowledgeSettings::VECTOR_DIMENSIONS
  OPENROUTER_EMBEDDINGS_UNAVAILABLE = 'OpenRouter embeddings are not configured.'.freeze
  SEARCH_DOCUMENT_INPUT_TYPE = 'search_document'.freeze
  SEARCH_QUERY_INPUT_TYPE = 'search_query'.freeze
  EMBEDDING_INPUT_TYPES = [SEARCH_DOCUMENT_INPUT_TYPE, SEARCH_QUERY_INPUT_TYPE].freeze

  attr_reader :embedding_model

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

  def get_embedding(content, model: @embedding_model, input_type: nil)
    return [] if content.blank?

    raise embeddings_unavailable_error if model.blank?

    input_type = normalize_input_type(input_type)
    provider = Llm::Config.provider_for_model(model, account: @account)
    observability = instrumentation_params(content, model, provider, input_type: input_type)
    instrument_embedding_call(observability) do
      embedding_for_provider(content, model, provider, observability, input_type: input_type)
    end
  rescue RubyLLM::Error, RubyLLM::ConfigurationError => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def instrumentation_params(content, model, provider = nil, input_type: nil)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      provider: provider || Llm::Config.provider_for_model(model, account: @account),
      input: content,
      input_type: input_type,
      feature_name: 'embedding',
      account_id: @account_id
    }.compact
  end

  def embedding_for_provider(content, model, provider, observability, input_type: nil)
    return openrouter_embedding(content, model, input_type: input_type) if provider == 'openrouter'

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

  def openrouter_embedding(content, model, input_type: nil)
    raise embeddings_unavailable_error if Llm::Config.api_key('openrouter', account: @account).blank?

    result = Llm::Runtime.embed(
      feature: :help_center_search,
      account: @account,
      model: model,
      input: content,
      observability: instrumentation_params(content, model, 'openrouter', input_type: input_type).merge(runtime_mode: 'captain_embedding'),
      options: { dimensions: VECTOR_DIMENSIONS, input_type: input_type }.compact
    )
    vector = result.vectors.first
    raise EmbeddingsError, 'OpenRouter embedding response did not include a vector.' unless vector.is_a?(Array)

    vector
  end

  def normalize_input_type(input_type)
    return if input_type.blank?

    input_type = input_type.to_s
    return input_type if EMBEDDING_INPUT_TYPES.include?(input_type)

    raise ArgumentError, "Unsupported embedding input_type: #{input_type}"
  end

  def embedding_dimensions_for(model)
    return unless model.to_s.match?(%r{(^|/)text-embedding-3-})

    VECTOR_DIMENSIONS
  end

  def embeddings_unavailable_error
    EmbeddingsUnavailableError.new(OPENROUTER_EMBEDDINGS_UNAVAILABLE)
  end
end
