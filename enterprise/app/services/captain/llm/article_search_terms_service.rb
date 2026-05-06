# frozen_string_literal: true

class Captain::Llm::ArticleSearchTermsService < Llm::BaseAiService
  include Integrations::LlmInstrumentation
  SEARCH_TERM_TEMPERATURE = 0.2

  def initialize(article)
    super()
    @article = article
  end

  def generate
    return [] if source_content.blank?
    return nil unless provider_configured?

    response = instrument_llm_call(instrumentation_params) do
      llm_chat = chat(model: model)
                 .with_schema(Captain::Llm::Schemas::SearchTermCollection)
                 .with_instructions(system_prompt)

      ask_chat(llm_chat, source_content)
    end

    parse_response(response.content)
  rescue RubyLLM::Error => e
    Rails.logger.error("Article search terms LLM API Error for article #{article.id}: #{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.error("Article search terms generation failed for article #{article.id}: #{e.class} #{e.message}")
    nil
  end

  private

  attr_reader :article

  def setup_temperature
    @temperature = SEARCH_TERM_TEMPERATURE
  end

  def system_prompt
    <<~SYSTEM_PROMPT_MESSAGE
      For the provided article content, generate potential search query keywords and snippets that can be used to generate the embeddings.
      Ensure the search terms are as diverse as possible but capture the essence of the article and are super related to the articles.
      Don't return any terms if there aren't any terms of relevance.
    SYSTEM_PROMPT_MESSAGE
  end

  def source_content
    @source_content ||= "title: #{article.title} \n description: #{article.description} \n content: #{article.content}"
  end

  def provider_configured?
    provider = Llm::Config.provider_for_model(model, account: article.account)
    return true if Llm::Config.api_key(provider, account: article.account).present?

    Rails.logger.warn(
      "Skipping article search term generation for article #{article.id}: " \
      "API key missing for provider #{provider}"
    )
    false
  end

  def llm_model_account
    article.account
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.article_search_terms',
      model: model,
      temperature: temperature,
      feature_name: 'article_search_terms',
      account_id: article.account_id,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: source_content }
      ]
    }
  end

  def parse_response(content)
    return [] unless content.is_a?(Hash)

    Array(content.with_indifferent_access[:search_terms]).filter_map do |term|
      value = term.to_s.strip
      value.presence
    end.uniq
  rescue StandardError => e
    Rails.logger.error("Error parsing article search term response for article #{article.id}: #{e.message}")
    []
  end
end
