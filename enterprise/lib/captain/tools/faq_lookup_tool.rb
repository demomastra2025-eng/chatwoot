class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:)
    log_tool_usage('searching', { query: query })

    responses = semantic_responses(query)
    lookup_strategy = 'semantic'

    if responses.blank?
      responses = lexical_fallback_responses(query)
      lookup_strategy = 'lexical' if responses.any?
    end

    log_tool_usage('found_results', { query: query, count: responses.size, strategy: lookup_strategy })
    faq_payload(query: query, responses: responses, lookup_strategy: lookup_strategy)
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError => e
    Rails.logger.warn "Captain::Tools::FaqLookupTool semantic lookup unavailable: #{e.class}: #{e.message}"
    responses = lexical_fallback_responses(query)
    faq_payload(query: query, responses: responses, lookup_strategy: 'lexical')
  end

  private

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

  def faq_payload(query:, responses:, error: nil, lookup_strategy: nil)
    payload = {
      query: query,
      total_count: responses.size,
      matches: responses.map { |response| response_payload(response) }
    }
    payload[:lookup_strategy] = lookup_strategy if lookup_strategy.present?
    payload[:error] = error if error.present?

    JSON.pretty_generate(payload)
  end

  def response_payload(response)
    {
      id: response.id,
      question: response.question,
      answer: response.answer,
      source: response.documentable&.try(:external_link),
      created_at: response.created_at&.iso8601,
      updated_at: response.updated_at&.iso8601
    }.compact
  end
end
