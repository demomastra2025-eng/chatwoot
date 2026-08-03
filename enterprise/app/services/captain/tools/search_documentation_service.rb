require 'timeout'

class Captain::Tools::SearchDocumentationService < Captain::Tools::BaseTool
  SEMANTIC_RESULT_LIMIT = 5
  SEMANTIC_LOOKUP_TIMEOUT_SECONDS = 8
  TOTAL_LOOKUP_TIMEOUT_SECONDS = 12
  SEMANTIC_DISTANCE_THRESHOLD = 0.3

  class TotalLookupTimeout < Timeout::Error; end

  def self.name
    'search_documentation'
  end
  description 'Search and retrieve documentation from knowledge base'

  param :query, desc: 'Search Query', required: true

  def execute(query:)
    query = query.to_s.squish
    return tool_failure('query is required') if query.blank?

    execute_lookup(query)
  rescue StandardError => e
    Rails.logger.error do
      "#{self.class.name} failed for assistant #{assistant.id}: #{e.class} - #{e.message}"
    end

    tool_failure('Documentation search is temporarily unavailable. No documentation context could be retrieved for this request.')
  end

  private

  def execute_lookup(query)
    Rails.logger.info { "#{self.class.name}: #{query}" }
    return 'No FAQs found for the given query' unless knowledge_available?

    translated_query = query

    Timeout.timeout(TOTAL_LOOKUP_TIMEOUT_SECONDS, TotalLookupTimeout) do
      translated_query = translated_query_for(query)
      responses = lookup_responses(translated_query, query)
      formatted_responses_or_empty(responses)
    end
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError, Timeout::Error => e
    semantic_fallback(query, translated_query, e)
  end

  def semantic_fallback(query, translated_query, error)
    log_semantic_unavailable(error)
    translated_query ||= query

    structured_fallback_payload(
      query: query,
      translated_query: translated_query,
      responses: lexical_fallback_responses(query, translated_query),
      fallback_reason: semantic_error_fallback_reason(error)
    )
  end

  def knowledge_available?
    assistant.account.captain_assistant_responses.approved.visible_to_assistant(assistant.id).exists? ||
      Captain::DocumentChunk.where(account_id: assistant.account_id).visible_to_assistant(assistant.id).exists?
  end

  def translated_query_for(query)
    Captain::Llm::TranslateQueryService
      .new(account: assistant.account)
      .translate(query, target_language: assistant.account.locale_english_name)
  end

  def lookup_responses(query, fallback_query = nil)
    responses = semantic_responses(query)
    return responses if responses.any?

    lexical_fallback_responses(query, fallback_query)
  end

  def formatted_responses_or_empty(responses)
    return 'No FAQs found for the given query' if responses.empty?

    responses.map { |response| format_response(response) }.join
  end

  def log_semantic_unavailable(error)
    Rails.logger.warn do
      "#{self.class.name} semantic lookup unavailable for assistant #{assistant.id}: #{error.class} - #{error.message}"
    end
  end

  def semantic_error_fallback_reason(error)
    return 'lookup_timeout' if error.is_a?(TotalLookupTimeout)
    return 'semantic_not_configured' if error.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError) ||
                                        error.is_a?(RubyLLM::ConfigurationError)
    return 'semantic_timeout' if error.is_a?(Timeout::Error)

    'semantic_unavailable'
  end

  def structured_fallback_payload(query:, translated_query:, responses:, fallback_reason:)
    JSON.pretty_generate(
      {
        query: query,
        translated_query: translated_query,
        lookup_strategy: 'lexical',
        total_count: responses.size,
        matches: responses.map { |response| structured_response_payload(response) },
        retrieval_trace: {
          strategy: 'lexical',
          degraded: true,
          semantic_attempted: true,
          fallback_reason: fallback_reason,
          match_count: responses.size,
          response_ids: response_ids_for(responses),
          document_ids: document_ids_for(responses),
          document_chunk_ids: document_chunk_ids_for(responses),
          embedding_status_counts: embedding_status_counts
        }.compact
      }
    )
  end

  def structured_response_payload(response)
    return structured_document_chunk_payload(response) if response.is_a?(Captain::DocumentChunk)

    {
      type: 'faq_response',
      id: response.id,
      question: response.question,
      answer: response.answer,
      source: response.documentable&.try(:external_link),
      document_chunk_id: response.document_chunk_id
    }.compact
  end

  def structured_document_chunk_payload(chunk)
    {
      type: 'document_chunk',
      id: chunk.id,
      document_id: chunk.document_id,
      document_chunk_id: chunk.id,
      chunk_index: chunk.chunk_index,
      answer: chunk.content,
      source: chunk.document.external_link,
      embedding_status: chunk.embedding_status
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
    Captain::DocumentChunk.where(account_id: assistant.account_id)
                          .visible_to_assistant(assistant.id)
                          .group(:embedding_status).count.presence
  end

  def semantic_responses(query)
    Timeout.timeout(SEMANTIC_LOOKUP_TIMEOUT_SECONDS) do
      candidates = Captain::DocumentChunk.search(query, account_id: assistant.account_id)
                                         .visible_to_assistant(assistant.id)
                                         .where(account_id: assistant.account_id)
                                         .limit(SEMANTIC_RESULT_LIMIT)
                                         .to_a
      candidates.select! { |candidate| semantic_distance_acceptable?(candidate) }
      Captain::Documents::Reranker.new(account: assistant.account).call(
        query: query,
        documents: candidates,
        top_n: SEMANTIC_RESULT_LIMIT
      ).documents
    end
  end

  def semantic_distance_acceptable?(candidate)
    distance = candidate.respond_to?(:neighbor_distance) ? candidate.neighbor_distance : nil
    distance.present? && distance.to_f <= SEMANTIC_DISTANCE_THRESHOLD
  end

  def lexical_fallback_responses(*queries)
    queries.compact.each do |candidate_query|
      tokens = lexical_tokens(candidate_query)
      next if tokens.blank?

      faq_responses = lexical_faq_responses(tokens)
      return faq_responses if faq_responses.any?

      document_chunks = lexical_document_chunks(tokens)
      return document_chunks if document_chunks.any?
    end

    Captain::AssistantResponse.none
  end

  def lexical_faq_responses(tokens)
    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end.join(' OR ')
    bind_values = lexical_bind_values(tokens)

    assistant.account.captain_assistant_responses
             .approved
             .visible_to_assistant(assistant.id)
             .where(conditions, bind_values)
             .ordered
             .limit(5)
  end

  def lexical_document_chunks(tokens)
    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(captain_document_chunks.content) LIKE :term_#{index}"
    end.join(' OR ')

    Captain::DocumentChunk.where(account_id: assistant.account_id)
                          .visible_to_assistant(assistant.id)
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

  def format_response(response)
    return format_document_chunk(response) if response.is_a?(Captain::DocumentChunk)

    formatted_response = "
        Question: #{response.question}
        Answer: #{response.answer}
        "
    if response.documentable.present? && response.documentable.try(:external_link)
      formatted_response += "
          Source: #{response.documentable.external_link}
          "
    end

    formatted_response
  end

  def format_document_chunk(chunk)
    formatted_response = "
        Source Chunk: #{chunk.content}
        "
    if chunk.document.external_link.present?
      formatted_response += "
          Source: #{chunk.document.external_link}
          "
    end

    formatted_response
  end
end
