# frozen_string_literal: true

require 'digest'
require 'timeout'

class Captain::Knowledge::AnswerCache
  DEFAULT_TTL = 24.hours
  CACHEABLE_STRATEGIES = %w[semantic_chunk semantic_faq].freeze
  RETRIEVAL_VERSION = 'faq-response-v2'
  QUERY_EMBEDDING_TIMEOUT_SECONDS = 4

  def initialize(account:, assistant:, query:, semantic: true, ttl: DEFAULT_TTL)
    @account = account
    @assistant = assistant
    @query = query.to_s
    @semantic = semantic
    @ttl = ttl
  end

  def fetch(overrides: {})
    return unless enabled?

    if (entry = exact_entry)
      return decorate_hit_payload(entry, match: 'exact', overrides: overrides)
    end

    entry = semantic_entry
    decorate_hit_payload(entry, match: 'semantic', overrides: overrides) if entry.present?
  rescue StandardError => e
    log_cache_error('read', e)
    nil
  end

  def write(payload)
    return payload unless enabled? && cacheable_payload?(payload)

    entry = Captain::KnowledgeAnswerCacheEntry.find_or_initialize_by(
      account: account,
      assistant: assistant,
      query_sha256: query_sha256,
      source_fingerprint: source_fingerprint
    )
    entry.assign_attributes(cache_attributes(payload, entry))
    entry.save!

    decorate_store_payload(payload, entry: entry)
  rescue StandardError => e
    log_cache_error('write', e)
    payload
  end

  private

  attr_reader :account, :assistant, :query, :semantic, :ttl

  def cache_attributes(payload, entry)
    attributes = {
      query: normalized_query,
      payload: stored_payload(payload),
      expires_at: ttl.from_now
    }
    embedding = safe_query_embedding
    attributes[:embedding] = embedding if embedding.present? || entry.new_record?
    attributes
  end

  def enabled?
    semantic && account.present? && assistant.present? && assistant.account_id == account.id && normalized_query.present?
  end

  def exact_entry
    cache_scope.find_by(query_sha256: query_sha256)
  end

  def semantic_entry
    return unless cache_scope.where.not(embedding: nil).exists?

    Captain::KnowledgeAnswerCacheEntry.semantic_match(
      embedding: query_embedding,
      account: account,
      assistant: assistant,
      source_fingerprint: source_fingerprint
    )
  end

  def cache_scope
    @cache_scope ||= Captain::KnowledgeAnswerCacheEntry
                     .for_scope(account: account, assistant: assistant, source_fingerprint: source_fingerprint)
                     .active
  end

  def record_hit!(entry)
    entry.update!(hit_count: entry.hit_count.to_i + 1, last_hit_at: Time.current)
    entry.reload
  end

  def decorate_hit_payload(entry, match:, overrides: {})
    entry = record_hit!(entry)
    payload = normalized_payload(entry.payload).merge(stringified_hash(overrides))
    payload['retrieval_trace'] ||= {}
    payload['retrieval_trace']['answer_cache'] = {
      'enabled' => true,
      'hit' => true,
      'match' => match,
      'entry_id' => entry.id,
      'hit_count' => entry.hit_count,
      'source_fingerprint' => source_fingerprint,
      'semantic_distance' => semantic_distance(entry, match)
    }.compact
    payload
  end

  def decorate_store_payload(payload, entry:)
    normalized_payload(payload).tap do |decorated|
      decorated['retrieval_trace'] ||= {}
      decorated['retrieval_trace']['answer_cache'] = {
        'enabled' => true,
        'hit' => false,
        'stored' => true,
        'entry_id' => entry.id,
        'source_fingerprint' => source_fingerprint
      }.compact
    end
  end

  def semantic_distance(entry, match)
    return unless match == 'semantic' && entry.respond_to?(:neighbor_distance)

    entry.neighbor_distance
  end

  def cacheable_payload?(payload)
    normalized = normalized_payload(payload)
    trace = normalized['retrieval_trace'].to_h
    CACHEABLE_STRATEGIES.include?(normalized['lookup_strategy']) &&
      normalized['total_count'].to_i.positive? &&
      trace['degraded'] != true
  end

  def stored_payload(payload)
    normalized_payload(payload).tap do |normalized|
      normalized['retrieval_trace']&.delete('answer_cache')
    end
  end

  def normalized_payload(payload)
    JSON.parse(JSON.generate(payload.as_json))
  end

  def stringified_hash(hash)
    hash.to_h.transform_keys(&:to_s)
  end

  def normalized_query
    @normalized_query ||= query.squish.downcase
  end

  def query_sha256
    @query_sha256 ||= Digest::SHA256.hexdigest(normalized_query)
  end

  def query_embedding
    @query_embedding ||= Timeout.timeout(QUERY_EMBEDDING_TIMEOUT_SECONDS) do
      Captain::Llm::EmbeddingService.new(account_id: account.id).get_embedding(
        normalized_query,
        input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE
      )
    end
  end

  def safe_query_embedding
    query_embedding
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError => e
    log_cache_error('embedding', e)
    nil
  end

  def source_fingerprint
    @source_fingerprint ||= Digest::SHA256.hexdigest(
      [
        RETRIEVAL_VERSION,
        account.id,
        scope_fingerprint(account.captain_documents),
        scope_fingerprint(Captain::DocumentChunk.where(account_id: account.id)),
        scope_fingerprint(account.captain_assistant_responses.approved)
      ].join(':')
    )
  end

  def scope_fingerprint(scope)
    "#{scope.count}:#{precise_timestamp(scope.maximum(:updated_at))}"
  end

  def precise_timestamp(value)
    value&.utc&.iso8601(6)
  end

  def log_cache_error(operation, error)
    Rails.logger.warn do
      "#{self.class.name} #{operation} skipped for assistant #{assistant&.id}: #{error.class} - #{error.message}"
    end
  end
end
