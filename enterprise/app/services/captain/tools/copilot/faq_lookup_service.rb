class Captain::Tools::Copilot::FaqLookupService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'faq_lookup'
  end

  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: :string, desc: 'The question or topic to search for in the FAQ database', required: true

  def execute(query:, semantic: true)
    translated_query = semantic ? translated_query_for(query) : query
    responses, lookup_strategy, fallback_reason = lookup_responses(translated_query, query, semantic: semantic)

    faq_result_payload(query: query, translated_query: translated_query, responses: responses, lookup_strategy: lookup_strategy,
                       trace_context: trace_context(semantic_attempted: semantic, fallback_reason: fallback_reason))
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError => e
    log_semantic_unavailable(e)
    translated_query ||= query

    faq_result_payload(
      query: query,
      translated_query: translated_query,
      responses: lexical_fallback_responses(translated_query, query),
      lookup_strategy: 'lexical',
      trace_context: trace_context(semantic_attempted: true, fallback_reason: 'semantic_unavailable')
    )
  rescue StandardError => e
    Rails.logger.error do
      "#{self.class.name} failed for assistant #{assistant.id}: #{e.class} - #{e.message}"
    end

    tool_failure('Documentation search is temporarily unavailable. No documentation context could be retrieved for this request.')
  end

  private

  def translated_query_for(query)
    Captain::Llm::TranslateQueryService
      .new(account: account)
      .translate(query, target_language: account.locale_english_name)
  end

  def lookup_responses(query, fallback_query = nil, semantic: true)
    if semantic
      responses = semantic_responses(query)
      return [responses, 'semantic_chunk', nil] if responses.any?
    end

    responses = lexical_fallback_responses(query, fallback_query)
    [responses, 'lexical', fallback_reason_for(semantic: semantic)]
  end

  def fallback_reason_for(semantic: true)
    return unless semantic
    return 'chunk_embeddings_unindexed' if assistant.document_chunks.needs_embedding_reindex.exists?

    'semantic_no_matches'
  end

  def faq_result_payload(query:, translated_query:, responses:, lookup_strategy:, trace_context: {})
    payload = {
      query: query,
      translated_query: translated_query,
      total_count: responses.size,
      lookup_strategy: lookup_strategy,
      matches: responses.map { |response| response_payload(response) },
      retrieval_trace: retrieval_trace(
        translated_query: translated_query,
        responses: responses,
        lookup_strategy: lookup_strategy,
        trace_context: trace_context
      )
    }.compact

    formatted_payload(payload)
  end

  def trace_context(semantic_attempted:, fallback_reason: nil)
    {
      semantic_attempted: semantic_attempted,
      fallback_reason: fallback_reason
    }
  end

  def retrieval_trace(translated_query:, responses:, lookup_strategy:, trace_context: {})
    {
      translated_query: translated_query,
      strategy: lookup_strategy,
      degraded: trace_context[:fallback_reason].present?,
      semantic_attempted: trace_context[:semantic_attempted],
      fallback_reason: trace_context[:fallback_reason],
      match_count: responses.size,
      response_ids: response_ids_for(responses),
      document_ids: document_ids_for(responses),
      document_chunk_ids: document_chunk_ids_for(responses),
      embedding_status_counts: embedding_status_counts,
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
    assistant.document_chunks.group(:embedding_status).count.presence
  end

  def sources_for(responses)
    responses.filter_map do |response|
      response.is_a?(Captain::DocumentChunk) ? response.document.external_link : response.documentable&.try(:external_link)
    end.uniq
  end

  def log_semantic_unavailable(error)
    Rails.logger.warn do
      "#{self.class.name} semantic lookup unavailable for assistant #{assistant.id}: #{error.class} - #{error.message}"
    end
  end

  def semantic_responses(query)
    Captain::DocumentChunk.search(query, account_id: account.id)
                          .where(assistant_id: assistant.id)
                          .limit(5)
  end

  def lexical_fallback_responses(*queries)
    tokens = lexical_tokens(*queries)
    return Captain::AssistantResponse.none if tokens.blank?

    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end.join(' OR ')
    bind_values = tokens.each_with_index.to_h do |token, index|
      ["term_#{index}".to_sym, "%#{ActiveRecord::Base.sanitize_sql_like(token.downcase)}%"]
    end

    assistant.responses
             .approved
             .where(account_id: account.id)
             .where(conditions, bind_values)
             .ordered
             .limit(5)
  end

  def lexical_tokens(*queries)
    queries.compact.join(' ').downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.uniq.first(5)
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
