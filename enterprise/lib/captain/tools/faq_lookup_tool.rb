class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  SEMANTIC_RESULT_LIMIT = 5

  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:, semantic: true)
    log_tool_usage('searching', { query: query })

    cache = answer_cache(query: query, semantic: semantic)
    cached_payload = cache.fetch(overrides: { query: query })
    return JSON.pretty_generate(cached_payload) if cached_payload.present?

    JSON.pretty_generate(cache.write(semantic_payload(query: query, semantic: semantic)))
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError, Timeout::Error => e
    Rails.logger.warn "Captain::Tools::FaqLookupTool semantic lookup unavailable: #{e.class}: #{e.message}"
    JSON.pretty_generate(semantic_unavailable_payload(query, error: e))
  end

  private

  def semantic_payload(query:, semantic:)
    responses, lookup_strategy, fallback_reason, rerank_trace = lookup_responses(query, semantic: semantic)
    log_tool_usage('found_results', { query: query, count: responses.size, strategy: lookup_strategy })

    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: lookup_strategy,
      trace_context: trace_context(semantic_attempted: semantic, fallback_reason: fallback_reason, rerank: rerank_trace)
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
    return 'semantic_not_configured' if error.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError) ||
                                        error.is_a?(RubyLLM::ConfigurationError)
    return 'semantic_timeout' if error.is_a?(Timeout::Error)

    'semantic_unavailable'
  end

  def lookup_responses(query, semantic: true)
    responses, rerank_trace = semantic ? semantic_responses(query) : [Captain::DocumentChunk.none, nil]
    lookup_strategy = semantic ? 'semantic_chunk' : 'lexical'
    fallback_reason = nil

    if responses.blank?
      responses = lexical_fallback_responses(query)
      fallback_reason = fallback_reason_for_empty_semantic if semantic
      lookup_strategy = 'lexical'
    end

    [responses, lookup_strategy, fallback_reason, rerank_trace]
  end

  def semantic_responses(query)
    candidates = Captain::DocumentChunk.search(query, account_id: account.id)
                                       .visible_to_assistant(assistant.id)
                                       .where(account_id: account.id)
                                       .limit(SEMANTIC_RESULT_LIMIT)
                                       .to_a
    rerank_result = Captain::Documents::Reranker.new(account: account).call(
      query: query,
      documents: candidates,
      top_n: SEMANTIC_RESULT_LIMIT
    )
    [rerank_result.documents, rerank_result.trace]
  end

  def fallback_reason_for_empty_semantic
    return 'chunk_embeddings_unindexed' if visible_document_chunks.needs_embedding_reindex.exists?

    'semantic_no_matches'
  end

  def lexical_fallback_responses(query)
    tokens = lexical_tokens(query)
    return Captain::AssistantResponse.none if tokens.blank?

    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end.join(' OR ')
    bind_values = tokens.each_with_index.to_h do |token, index|
      ["term_#{index}".to_sym, "%#{ActiveRecord::Base.sanitize_sql_like(token.downcase)}%"]
    end

    account.captain_assistant_responses
           .approved
           .visible_to_assistant(assistant.id)
           .where(conditions, bind_values)
           .ordered
           .limit(5)
  end

  def lexical_tokens(query)
    query.to_s.downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.first(5)
  end

  def answer_cache(query:, semantic:)
    Captain::Knowledge::AnswerCache.new(account: account, assistant: assistant, query: query, semantic: semantic)
  end

  def faq_payload(query:, responses:, lookup_strategy: nil, trace_context: {})
    payload = {
      query: query,
      total_count: responses.size,
      matches: responses.map { |response| response_payload(response) },
      retrieval_trace: retrieval_trace(
        responses: responses,
        lookup_strategy: lookup_strategy,
        trace_context: trace_context
      )
    }
    payload[:lookup_strategy] = lookup_strategy if lookup_strategy.present?

    payload
  end

  def trace_context(semantic_attempted:, fallback_reason: nil, rerank: nil)
    {
      semantic_attempted: semantic_attempted,
      fallback_reason: fallback_reason,
      rerank: rerank
    }.compact
  end

  def retrieval_trace(responses:, lookup_strategy:, trace_context: {})
    {
      strategy: lookup_strategy,
      degraded: trace_context[:fallback_reason].present?,
      semantic_attempted: trace_context[:semantic_attempted],
      fallback_reason: trace_context[:fallback_reason],
      match_count: responses.size,
      response_ids: response_ids_for(responses),
      document_ids: document_ids_for(responses),
      document_chunk_ids: document_chunk_ids_for(responses),
      embedding_status_counts: embedding_status_counts,
      rerank: trace_context[:rerank],
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

  def visible_document_chunks
    Captain::DocumentChunk.where(account_id: account.id).visible_to_assistant(assistant.id)
  end

  def sources_for(responses)
    responses.filter_map do |response|
      response.is_a?(Captain::DocumentChunk) ? response.document.external_link : response.documentable&.try(:external_link)
    end.uniq
  end

  def response_payload(response)
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
    }.compact
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
