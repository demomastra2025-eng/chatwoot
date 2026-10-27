class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end
  class EmbeddingsUnavailableError < EmbeddingsError; end

  VECTOR_DIMENSIONS = Captain::KnowledgeSettings::VECTOR_DIMENSIONS
  OPENROUTER_EMBEDDINGS_UNAVAILABLE = 'OpenRouter embeddings are not configured.'.freeze
  SEARCH_DOCUMENT_INPUT_TYPE = 'search_document'.freeze
  SEARCH_QUERY_INPUT_TYPE = 'search_query'.freeze
  EMBEDDING_INPUT_TYPES = [SEARCH_DOCUMENT_INPUT_TYPE, SEARCH_QUERY_INPUT_TYPE].freeze
  # One request carries at most this many texts and characters (the limits of the experiment that chose the model); a longer list goes
  # in several requests, in order.
  BATCH_MAX_INPUTS = 64
  BATCH_MAX_CHARS = 40_000
  # Tokens per character that the Gemini tokenizer measured on a real clinic catalog (Russian text): an estimate for plans and logs only.
  TOKENS_PER_CHAR = 0.41

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

  # The fingerprint of an embedded text: a row whose text still has this checksum (and whose vector was made by the model in force)
  # needs no new vector.
  def self.checksum(text)
    Digest::SHA256.hexdigest(text.to_s.squish)
  end

  # The unit vector of a vector: the form in which the models with `has_neighbors normalize: true` keep it. A vector cut to 1536 numbers
  # (Gemini gives 3072) is not unit length; the writers that bypass the models store it normalized, like the models do.
  def self.normalize(vector)
    norm = Math.sqrt(vector.sum { |value| value * value })
    norm.zero? ? vector : vector.map { |value| value / norm }
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

  # The vectors of many texts, in the order of the texts, in as few requests as the limits allow (one for a normal list). A blank text
  # is a mistake of the caller, not an empty vector. Every vector has exactly VECTOR_DIMENSIONS numbers, as for a single text.
  def get_embeddings(contents, model: @embedding_model, input_type: nil)
    texts = embedding_texts(contents)
    return [] if texts.empty?
    raise embeddings_unavailable_error if model.blank?

    input_type = normalize_input_type(input_type)
    provider = Llm::Config.provider_for_model(model, account: @account)
    batches_of(texts).flat_map do |batch|
      observability = instrumentation_params(batch.join("\n"), model, provider, input_type: input_type)
      runtime_embeddings(batch, model, provider, observability, input_type: input_type)
    end
  rescue RubyLLM::Error, RubyLLM::ConfigurationError => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def embedding_texts(contents)
    texts = Array(contents).map(&:to_s)
    raise ArgumentError, 'Embedding input must not be blank.' if texts.any?(&:blank?)

    texts
  end

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
    runtime_embedding(content, model, provider, observability, input_type: input_type)
  end

  def runtime_embedding(content, model, provider, observability, input_type: nil)
    runtime_embeddings([content], model, provider, observability, input_type: input_type).first
  end

  # One request to the runtime for a list of texts, answered with one vector per text (see #checked_vectors).
  def runtime_embeddings(contents, model, provider, observability, input_type: nil)
    raise embeddings_unavailable_error if Llm::Config.api_key('openrouter', account: @account).blank?

    result = Llm::Runtime.embed(
      feature: :help_center_search,
      account: @account,
      model: model,
      input: contents.one? ? contents.first : contents,
      observability: observability.merge(provider: provider.presence || 'openrouter', runtime_mode: 'captain_embedding'),
      options: { dimensions: VECTOR_DIMENSIONS, input_type: input_type }.compact
    )
    verify_served_model!(result, model)
    checked_vectors(result.vectors, contents.size, model)
  end

  # The model that answered is the model that was asked for. OpenRouter names it without the vendor ("gemini-embedding-001" for
  # "google/gemini-embedding-001"); a response that names another model is refused (vectors of two models cannot be compared).
  def verify_served_model!(result, requested)
    served = result.respond_to?(:model) ? result.model.to_s : ''
    return if served.blank? || served.split('/').last.casecmp?(requested.to_s.split('/').last)

    raise EmbeddingsError, "Embedding model #{requested} was asked for, #{served} answered."
  end

  # The answer is checked here too, whatever the runtime did: one vector per text, each with exactly VECTOR_DIMENSIONS numbers (a model
  # that ignores the requested size must never reach a vector(1536) column).
  def checked_vectors(vectors, expected_count, model)
    unless vectors.is_a?(Array) && vectors.size == expected_count && vectors.all?(Array)
      raise EmbeddingsError, 'OpenRouter embedding response did not include a vector.'
    end

    wrong = vectors.find { |vector| vector.size != VECTOR_DIMENSIONS }
    raise EmbeddingsError, "Embedding model #{model} returned #{wrong.size} dimensions, expected #{VECTOR_DIMENSIONS}." if wrong

    vectors
  end

  def batches_of(texts)
    batches = [[]]
    chars = 0
    texts.each do |text|
      if batches.last.size >= BATCH_MAX_INPUTS || (chars + text.length > BATCH_MAX_CHARS && batches.last.any?)
        batches << []
        chars = 0
      end
      batches.last << text
      chars += text.length
    end
    batches
  end

  def normalize_input_type(input_type)
    return if input_type.blank?

    input_type = input_type.to_s
    return input_type if EMBEDDING_INPUT_TYPES.include?(input_type)

    raise ArgumentError, "Unsupported embedding input_type: #{input_type}"
  end

  def embeddings_unavailable_error
    EmbeddingsUnavailableError.new(OPENROUTER_EMBEDDINGS_UNAVAILABLE)
  end
end
