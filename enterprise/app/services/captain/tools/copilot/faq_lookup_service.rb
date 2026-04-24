class Captain::Tools::Copilot::FaqLookupService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'faq_lookup'
  end

  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: :string, desc: 'The question or topic to search for in the FAQ database', required: true

  def execute(query:)
    translated_query = Captain::Llm::TranslateQueryService
                       .new(account: account)
                       .translate(query, target_language: account.locale_english_name)

    responses = Captain::AssistantResponse.search(translated_query, account_id: account.id)
                                          .where(assistant_id: assistant.id, status: Captain::AssistantResponse.statuses[:approved])
                                          .limit(5)

    formatted_payload(
      query: query,
      translated_query: translated_query,
      total_count: responses.size,
      matches: responses.map { |response| response_payload(response) }
    )
  rescue StandardError => e
    Rails.logger.error do
      "#{self.class.name} failed for assistant #{assistant.id}: #{e.class} - #{e.message}"
    end

    tool_failure('Documentation search is temporarily unavailable. No documentation context could be retrieved for this request.')
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
