class Captain::Tools::SearchReplyDocumentationService < RubyLLM::Tool
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

  def execute(query:)
    Rails.logger.info { "#{self.class.name}: #{query}" }

    translated_query = Captain::Llm::TranslateQueryService
                       .new(account: @account)
                       .translate(query, target_language: @account.locale_english_name)

    responses = search_responses(translated_query)
    return 'No FAQs found for the given query' if responses.empty?

    responses.map { |response| format_response(response) }.join
  end

  private

  attr_reader :assistant

  def search_responses(query)
    scoped_responses.search(query, account_id: @account.id)
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
