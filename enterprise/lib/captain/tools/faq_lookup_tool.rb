class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:)
    log_tool_usage('searching', { query: query })

    responses = Captain::AssistantResponse.search(query, account_id: account.id)
                                          .where(assistant_id: assistant.id, status: Captain::AssistantResponse.statuses[:approved])
                                          .limit(5)

    log_tool_usage('found_results', { query: query, count: responses.size })
    JSON.pretty_generate(
      query: query,
      total_count: responses.size,
      matches: responses.map { |response| response_payload(response) }
    )
  end

  private

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
