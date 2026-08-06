require 'timeout'

class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  SEMANTIC_RESULT_LIMIT = 5
  CACHE_FETCH_TIMEOUT_SECONDS = 3
  SEMANTIC_LOOKUP_TIMEOUT_SECONDS = 8
  TOTAL_LOOKUP_TIMEOUT_SECONDS = 12
  SEMANTIC_DISTANCE_THRESHOLD = 0.3
  SEMANTIC_SIMILARITY_THRESHOLD = 1.0 - SEMANTIC_DISTANCE_THRESHOLD

  class TotalLookupTimeout < Timeout::Error; end

  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:, semantic: true, voice_realtime: false)
    log_tool_usage('searching', { query: query })
    return JSON.pretty_generate(voice_realtime_payload(query)) if voice_realtime

    Timeout.timeout(TOTAL_LOOKUP_TIMEOUT_SECONDS, TotalLookupTimeout) do
      exact_payload = exact_faq_payload(query)
      return JSON.pretty_generate(exact_payload) if exact_payload.present?

      cache = answer_cache(query: query, semantic: semantic)
      cached_payload = bounded_cache_fetch(cache, query: query)
      return JSON.pretty_generate(cached_payload) if cached_payload.present?

      JSON.pretty_generate(cache.write(semantic_payload(query: query, semantic: semantic)))
    end
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError, Timeout::Error => e
    Rails.logger.warn "Captain::Tools::FaqLookupTool semantic lookup unavailable: #{e.class}: #{e.message}"
    JSON.pretty_generate(semantic_unavailable_payload(query, error: e))
  end

  private

  def exact_faq_payload(query)
    responses = Captain::AssistantResponse.exact_search(
      query,
      account_id: account.id,
      assistant_id: assistant.id,
      limit: SEMANTIC_RESULT_LIMIT
    )
    return if responses.blank?

    log_tool_usage('found_results', { query: query, count: responses.size, strategy: 'lexical_exact' })
    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: 'lexical_exact',
      trace_context: trace_context(semantic_attempted: false, relevance_check: exact_relevance_check(responses.size))
    )
  end

  def voice_realtime_payload(query)
    responses = lexical_fallback_responses(query)
    log_tool_usage('found_results', { query: query, count: responses.size, strategy: 'lexical_voice_realtime' })

    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: 'lexical_voice_realtime',
      trace_context: trace_context(semantic_attempted: false, fallback_reason: 'voice_realtime_fast_path')
    )
  end

  def semantic_payload(query:, semantic:)
    responses, lookup_strategy, lookup_failure_reason, relevance_check = lookup_responses(query, semantic: semantic)
    log_tool_usage('found_results', { query: query, count: responses.size, strategy: lookup_strategy })

    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: lookup_strategy,
      trace_context: trace_context(
        semantic_attempted: semantic,
        fallback_reason: lookup_strategy == 'lexical' && semantic ? lookup_failure_reason : nil,
        no_match_reason: lookup_strategy == 'semantic_faq' ? lookup_failure_reason : nil,
        relevance_check: relevance_check
      )
    )
  end

  def semantic_unavailable_payload(query, error: nil)
    faq_payload(
      query: query,
      responses: lexical_fallback_responses(query),
      lookup_strategy: 'lexical',
      trace_context: trace_context(semantic_attempted: true, fallback_reason: semantic_error_fallback_reason(error))
    )
  end

  def semantic_error_fallback_reason(error)
    return 'lookup_timeout' if error.is_a?(TotalLookupTimeout)
    return 'semantic_not_configured' if error.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError) ||
                                        error.is_a?(RubyLLM::ConfigurationError)
    return 'semantic_timeout' if error.is_a?(Timeout::Error)

    'semantic_unavailable'
  end

  def lookup_responses(query, semantic: true)
    if semantic
      responses, relevance_check = semantic_responses(query)
      return [responses, 'semantic_faq', nil, relevance_check] if responses.any?

      if relevance_check[:candidate_count].zero?
        responses = lexical_fallback_responses(query)
        return [responses, 'lexical', 'semantic_no_matches', relevance_check]
      end

      return [Captain::AssistantResponse.none, 'semantic_faq', 'relevance_threshold_not_met', relevance_check]
    end

    [lexical_fallback_responses(query), 'lexical', nil, nil]
  end

  def semantic_responses(query)
    Timeout.timeout(SEMANTIC_LOOKUP_TIMEOUT_SECONDS) do
      candidates = Captain::AssistantResponse.search(
        query,
        account_id: account.id,
        assistant_id: assistant.id,
        limit: SEMANTIC_RESULT_LIMIT
      ).to_a
      responses = candidates.select { |response| semantic_distance_acceptable?(response) }
      [responses, semantic_relevance_check(candidates, responses)]
    end
  end

  def semantic_relevance_check(candidates, responses)
    scores = candidates.filter_map { |response| semantic_similarity_score(response) }
    {
      metric: 'cosine_similarity',
      threshold: SEMANTIC_SIMILARITY_THRESHOLD,
      best_score: scores.max,
      candidate_count: candidates.size,
      passed: responses.any?
    }.compact
  end

  def exact_relevance_check(candidate_count)
    { metric: 'exact_match', threshold: 1.0, best_score: 1.0, candidate_count: candidate_count, passed: true }
  end

  def semantic_distance_acceptable?(response)
    distance = response.respond_to?(:neighbor_distance) ? response.neighbor_distance : nil
    distance.present? && distance.to_f <= SEMANTIC_DISTANCE_THRESHOLD
  end

  def bounded_cache_fetch(cache, query:)
    Timeout.timeout(CACHE_FETCH_TIMEOUT_SECONDS) do
      cache.fetch(overrides: { query: query })
    end
  end

  def lexical_fallback_responses(*queries)
    queries.compact.each do |candidate_query|
      faq_responses = Captain::AssistantResponse.lexical_search(
        candidate_query,
        account_id: account.id,
        assistant_id: assistant.id,
        limit: SEMANTIC_RESULT_LIMIT
      )
      return faq_responses if faq_responses.any?

      tokens = lexical_tokens(candidate_query)
      next if tokens.blank?

      document_chunks = lexical_document_chunks(tokens)
      return document_chunks if document_chunks.any?
    end

    Captain::AssistantResponse.none
  end

  def lexical_document_chunks(tokens)
    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(captain_document_chunks.content) LIKE :term_#{index}"
    end.join(' OR ')

    visible_document_chunks
      .where(conditions, lexical_bind_values(tokens))
      .order(:document_id, :chunk_index)
      .limit(5)
  end

  def lexical_bind_values(tokens)
    tokens.each_with_index.to_h do |token, index|
      ["term_#{index}".to_sym, "%#{ActiveRecord::Base.sanitize_sql_like(token.downcase)}%"]
    end
  end

  def lexical_tokens(*queries)
    queries.compact.join(' ').downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.uniq.first(5)
  end

  def answer_cache(query:, semantic:)
    Captain::Knowledge::AnswerCache.new(account: account, assistant: assistant, query: query, semantic: semantic)
  end

  def faq_payload(query:, responses:, lookup_strategy: nil, trace_context: {})
    payload = {
      query: query,
      total_count: responses.size,
      result: responses.any? ? 'found' : 'not_found',
      message: responses.any? ? nil : 'No relevant FAQ result found',
      matches: responses.map { |response| response_payload(response, lookup_strategy: lookup_strategy) },
      retrieval_trace: retrieval_trace(
        responses: responses,
        lookup_strategy: lookup_strategy,
        trace_context: trace_context
      )
    }
    payload[:lookup_strategy] = lookup_strategy if lookup_strategy.present?

    payload
  end

  def trace_context(semantic_attempted:, fallback_reason: nil, no_match_reason: nil, relevance_check: nil)
    {
      semantic_attempted: semantic_attempted,
      fallback_reason: fallback_reason,
      no_match_reason: no_match_reason,
      relevance_check: relevance_check
    }.compact
  end

  def retrieval_trace(responses:, lookup_strategy:, trace_context: {})
    {
      strategy: lookup_strategy,
      degraded: trace_context[:fallback_reason].present?,
      semantic_attempted: trace_context[:semantic_attempted],
      fallback_reason: trace_context[:fallback_reason],
      no_match_reason: trace_context[:no_match_reason],
      match_count: responses.size,
      response_ids: response_ids_for(responses),
      document_ids: document_ids_for(responses),
      document_chunk_ids: document_chunk_ids_for(responses),
      embedding_status_counts: embedding_status_counts,
      faq_embedding_counts: faq_embedding_counts,
      relevance_check: trace_context[:relevance_check],
      sources: sources_for(responses)
    }.compact
  end

  def response_ids_for(responses)
    responses.reject { |response| response.is_a?(Captain::DocumentChunk) }.map(&:id)
  end

  def document_ids_for(responses)
    responses.filter_map do |response|
      if response.is_a?(Captain::DocumentChunk)
        response.document_id
      elsif response.documentable_type == 'Captain::Document'
        response.documentable_id
      end
    end.uniq
  end

  def document_chunk_ids_for(responses)
    responses.filter_map do |response|
      response.is_a?(Captain::DocumentChunk) ? response.id : response.document_chunk_id
    end.uniq
  end

  def embedding_status_counts
    visible_document_chunks.group(:embedding_status).count.presence
  end

  def faq_embedding_counts
    {
      indexed: visible_faq_responses.where.not(embedding: nil).count,
      unindexed: visible_faq_responses.where(embedding: nil).count
    }
  end

  def visible_faq_responses
    account.captain_assistant_responses.approved.visible_to_assistant(assistant.id)
  end

  def visible_document_chunks
    Captain::DocumentChunk.where(account_id: account.id).visible_to_assistant(assistant.id)
  end

  def sources_for(responses)
    responses.filter_map do |response|
      response.is_a?(Captain::DocumentChunk) ? response.document.external_link : response.documentable&.try(:external_link)
    end.uniq
  end

  def response_payload(response, lookup_strategy:)
    return document_chunk_payload(response) if response.is_a?(Captain::DocumentChunk)

    {
      type: 'faq_response',
      id: response.id,
      question: response.question,
      answer: response.answer,
      source: response.documentable&.try(:external_link),
      document_chunk_id: response.document_chunk_id,
      created_at: response.created_at&.iso8601,
      updated_at: response.updated_at&.iso8601
    }.merge(response_relevance_payload(response, lookup_strategy: lookup_strategy)).compact
  end

  def response_relevance_payload(response, lookup_strategy:)
    return { score: 1.0, relevance_threshold: 1.0, relevance_threshold_passed: true } if lookup_strategy == 'lexical_exact'

    score = semantic_similarity_score(response)
    return {} if score.nil?

    {
      score: score,
      relevance_threshold: SEMANTIC_SIMILARITY_THRESHOLD,
      relevance_threshold_passed: score >= SEMANTIC_SIMILARITY_THRESHOLD
    }
  end

  def semantic_similarity_score(response)
    distance = response.respond_to?(:neighbor_distance) ? response.neighbor_distance : nil
    return if distance.blank?

    (1.0 - distance.to_f).round(6)
  end

  def document_chunk_payload(chunk)
    {
      type: 'document_chunk',
      id: chunk.id,
      document_id: chunk.document_id,
      document_chunk_id: chunk.id,
      chunk_index: chunk.chunk_index,
      answer: chunk.content,
      source: chunk.document.external_link,
      embedding_status: chunk.embedding_status,
      created_at: chunk.created_at&.iso8601,
      updated_at: chunk.updated_at&.iso8601
    }.compact
  end
end
