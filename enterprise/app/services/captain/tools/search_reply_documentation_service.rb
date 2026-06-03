require 'timeout'

class Captain::Tools::SearchReplyDocumentationService < RubyLLM::Tool
  SEMANTIC_LOOKUP_TIMEOUT_SECONDS = 8

  prepend Captain::Tools::Instrumentation
  include Captain::ToolResultOutput

  description 'Search and retrieve documentation/FAQs from knowledge base'

  param :query, desc: 'Search Query', required: true

  def initialize(account:, assistant: nil)
    @account = account
    @assistant = assistant
    super()
  end

  def name
    'search_documentation'
  end

  def active?
    true
  end

  def execute(query:)
    Rails.logger.info { "#{self.class.name}: #{query}" }

    translated_query = Captain::Llm::TranslateQueryService
                       .new(account: @account)
                       .translate(query, target_language: @account.locale_english_name)

    responses = search_responses(translated_query)
    formatted_responses_or_empty(responses)
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, RubyLLM::Error, RubyLLM::ConfigurationError, Timeout::Error => e
    log_semantic_unavailable(e)
    translated_query ||= query
    formatted_responses_or_empty(lexical_fallback_responses(translated_query, query))
  rescue StandardError => e
    Rails.logger.error do
      "#{self.class.name} failed for assistant #{assistant&.id}: #{e.class} - #{e.message}"
    end

    tool_failure('Documentation search is temporarily unavailable. No documentation context could be retrieved for this request.')
  end

  private

  attr_reader :assistant

  def search_responses(query)
    Timeout.timeout(SEMANTIC_LOOKUP_TIMEOUT_SECONDS) do
      scoped_responses.search(query, account_id: @account.id).to_a
    end
  end

  def formatted_responses_or_empty(responses)
    return 'No FAQs found for the given query' if responses.empty?

    responses.map { |response| format_response(response) }.join
  end

  def lexical_fallback_responses(*queries)
    tokens = lexical_tokens(*queries)
    return scoped_responses.none if tokens.blank?

    conditions = tokens.each_with_index.map do |_token, index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end.join(' OR ')
    bind_values = tokens.each_with_index.to_h do |token, index|
      ["term_#{index}".to_sym, "%#{ActiveRecord::Base.sanitize_sql_like(token.downcase)}%"]
    end

    scoped_responses.where(conditions, bind_values).ordered.limit(5)
  end

  def lexical_tokens(*queries)
    queries.compact.join(' ').downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.uniq.first(5)
  end

  def log_semantic_unavailable(error)
    Rails.logger.warn do
      "#{self.class.name} semantic lookup unavailable for assistant #{assistant&.id}: #{error.class} - #{error.message}"
    end
  end

  def scoped_responses
    @account.captain_assistant_responses
            .approved
            .visible_to_assistant(assistant&.id)
  end

  def format_response(response)
    result = "\nQuestion: #{response.question}\nAnswer: #{response.answer}\n"
    result += "Source: #{response.documentable.external_link}\n" if response.documentable.present? && response.documentable.try(:external_link)
    result
  end

  def tool_scope_name
    Captain::ToolAccess::SCOPE_ASSISTANT
  end

  def tool_definition
    definition = Captain::ToolRegistry.definition_for(name).to_h
    definition[:id] ||= name
    definition[:title] ||= name.to_s.humanize
    definition
  end

  def tool_safety_account
    @account
  end

  def tool_safety_feature
    :assistant
  end

  def tool_safety_preferences
    @account&.captain_preferences&.dig(:runtime)
  end

  def tool_runtime_context
    {}
  end
end
