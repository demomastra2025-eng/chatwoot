class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:, semantic: true)
    log_tool_usage('searching', { query: query })

    responses, lookup_strategy, fallback_reason = lookup_responses(query, semantic: semantic)

    log_tool_usage('found_results', { query: query, count: responses.size, strategy: lookup_strategy })
    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: lookup_strategy,
      trace_context: trace_context(semantic_attempted: semantic, fallback_reason: fallback_reason)
    )
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError => e
    Rails.logger.warn "Captain::Tools::FaqLookupTool semantic lookup unavailable: #{e.class}: #{e.message}"
    responses = lexical_fallback_responses(query)
    faq_payload(
      query: query,
      responses: responses,
      lookup_strategy: 'lexical',
      trace_context: trace_context(semantic_attempted: true, fallback_reason: 'semantic_unavailable')
    )
  end

  private

  def lookup_responses(query, semantic: true)
    responses = semantic ? semantic_responses(query) : Captain::AssistantResponse.none
    lookup_strategy = semantic ? 'semantic' : 'lexical'
    fallback_reason = nil

    if responses.blank?
      responses = lexical_fallback_responses(query)
      fallback_reason = 'semantic_no_matches' if semantic
      lookup_strategy = 'lexical'
    end

    [responses, lookup_strategy, fallback_reason]
  end

  def semantic_responses(query)
    Captain::AssistantResponse.search(query, account_id: account.id)
                              .where(assistant_id: assistant.id, status: Captain::AssistantResponse.statuses[:approved])
                              .limit(5)
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

    assistant.responses
             .approved
             .where(account_id: account.id)
             .where(conditions, bind_values)
             .ordered
             .limit(5)
  end

  def lexical_tokens(query)
    query.to_s.downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.first(5)
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

    JSON.pretty_generate(payload)
  end

  def trace_context(semantic_attempted:, fallback_reason: nil)
    {
      semantic_attempted: semantic_attempted,
      fallback_reason: fallback_reason
    }
  end

  def retrieval_trace(responses:, lookup_strategy:, trace_context: {})
    {
      strategy: lookup_strategy,
      degraded: trace_context[:fallback_reason].present?,
      semantic_attempted: trace_context[:semantic_attempted],
      fallback_reason: trace_context[:fallback_reason],
      match_count: responses.size,
      response_ids: responses.map(&:id),
      document_ids: document_ids_for(responses),
      document_chunk_ids: document_chunk_ids_for(responses),
      sources: sources_for(responses)
    }.compact
  end

  def document_ids_for(responses)
    responses.filter_map do |response|
      response.documentable_id if response.documentable_type == 'Captain::Document'
    end.uniq
  end

  def document_chunk_ids_for(responses)
    responses.filter_map(&:document_chunk_id).uniq
  end

  def sources_for(responses)
    responses.filter_map { |response| response.documentable&.try(:external_link) }.uniq
  end

  def response_payload(response)
    {
      id: response.id,
      question: response.question,
      answer: response.answer,
      source: response.documentable&.try(:external_link),
      document_chunk_id: response.document_chunk_id,
      created_at: response.created_at&.iso8601,
      updated_at: response.updated_at&.iso8601
    }.compact
  end
end
