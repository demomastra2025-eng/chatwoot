class Captain::Tools::SearchDocumentationService < Captain::Tools::BaseTool
  def self.name
    'search_documentation'
  end
  description 'Search and retrieve documentation from knowledge base'

  param :query, desc: 'Search Query', required: true

  def execute(query:)
    Rails.logger.info { "#{self.class.name}: #{query}" }
    return 'No FAQs found for the given query' unless knowledge_available?

    translated_query = translated_query_for(query)
    responses = lookup_responses(translated_query, query)
    formatted_responses_or_empty(responses)
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError => e
    log_semantic_unavailable(e)
    translated_query ||= query

    formatted_responses_or_empty(lexical_fallback_responses(translated_query, query))
  rescue StandardError => e
    Rails.logger.error do
      "#{self.class.name} failed for assistant #{assistant.id}: #{e.class} - #{e.message}"
    end

    tool_failure('Documentation search is temporarily unavailable. No documentation context could be retrieved for this request.')
  end

  private

  def knowledge_available?
    assistant.responses.approved.exists? || assistant.document_chunks.exists?
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

  def semantic_responses(query)
    Captain::DocumentChunk.search(query, account_id: assistant.account_id)
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
             .where(account_id: assistant.account_id)
             .where(conditions, bind_values)
             .ordered
             .limit(5)
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
