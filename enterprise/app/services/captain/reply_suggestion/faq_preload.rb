# frozen_string_literal: true

require 'timeout'

# The FAQ answers that are close to what the patient just wrote, found before the first model call of a reply suggestion instead of by a
# faq_lookup step (about 2.5 s; 53 of the 82 suggestions of the PROD profile of 27.10 made one). It is the search of faq_lookup, not
# another: the same vector index (Captain::AssistantResponse), the same model of the platform and the same threshold
# (Captain::Tools::FaqLookupTool::SEMANTIC_DISTANCE_THRESHOLD, similarity 0.7). faq_lookup stays for other questions, and for its
# other ways to an answer (the exact question, the corroboration of a weaker match, the knowledge graph).
#
# The message is embedded on a thread of its own while the router decides and the input is checked, because the model that embeds it is
# the same for every agent; the nearest answers are read when the agent is known, because what an agent may see is its own
# (visible_to_assistant). At most MAX_MATCHES answers above the threshold go to the prompt (Captain::AssistantPrompt), labelled as
# reference answers to use only if they match the question. Nothing here writes, and a failure only costs the saving.
class Captain::ReplySuggestion::FaqPreload
  MAX_MATCHES = 3
  # The nearest answers read, as faq_lookup reads them.
  CANDIDATES = Captain::Tools::FaqLookupTool::SEMANTIC_RESULT_LIMIT
  # The longest text embedded; a longer message is cut to its start, which holds the question.
  MAX_QUERY_CHARS = 600
  # A phone number, an IIN or any other number of nine digits or more says nothing about the question: it is not sent to the embedding
  # provider (faq_lookup sends the query the model wrote, never the whole message).
  LONG_NUMBER = /\+?\d(?:[\s().-]?\d){8,}/
  # The longest wait for the vector of the message, in seconds (the embedding request has its own, longer limits).
  EMBEDDING_WAIT_SECONDS = 3
  # The answers of one prompt may total this many characters, the first answer always whole.
  MAX_ANSWER_CHARS = 4000

  class << self
    # Starts embedding the latest words of the patient. nil when there is nothing to search: no text, or an account with no approved FAQ.
    def start(account:, text:)
      query = text.to_s.gsub(LONG_NUMBER, ' ').squish.first(MAX_QUERY_CHARS)
      return if query.blank? || !faq_present?(account)

      new(account: account, query: query)
    end

    private

    def faq_present?(account)
      Captain::AssistantResponse.approved.exists?(account_id: account.id)
    end
  end

  def initialize(account:, query:)
    @account = account
    @query = query
    @result = {}
    scope = Captain::Runtime::Council::ThreadScope.capture
    @thread = Thread.new { scope.run { with_runtime_caches { embed } } }
    @thread.report_on_exception = false
  end

  # [{ question:, answer:, score: }] of the agent's FAQ above the threshold, nearest first; [] for an agent without FAQ or when the
  # message could not be embedded.
  def matches(assistant)
    return [] unless assistant.faq_enabled? && assistant.faq_entries?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @thread.join(EMBEDDING_WAIT_SECONDS) }
    return [] if @result[:vector].blank?

    answers(nearest(assistant))
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] faq preload skipped error_class=#{e.class.name}")
    []
  end

  private

  # The thread reads the settings and the model catalog the way the run does (one read for the thread, not one per call).
  def with_runtime_caches(&)
    Llm::Config.with_runtime_cache do
      Llm::OpenRouterModelCatalog.with_model_configs_snapshot { Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot(&) }
    end
  end

  def embed
    embedder = Captain::Llm::EmbeddingService.new(account_id: @account.id)
    vector = Timeout.timeout(EMBEDDING_WAIT_SECONDS) do
      embedder.get_embedding(@query, input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    end
    @result = { vector: vector, model: embedder.embedding_model }
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] faq preload not embedded error_class=#{e.class.name}")
  end

  def nearest(assistant)
    Captain::AssistantResponse.nearest_to(
      @result[:vector], embedding_model: @result[:model], account_id: @account.id, assistant_id: assistant.id, limit: CANDIDATES
    ).to_a.select { |response| response.neighbor_distance.to_f <= Captain::Tools::FaqLookupTool::SEMANTIC_DISTANCE_THRESHOLD }
  end

  def answers(responses)
    kept = []
    responses.first(MAX_MATCHES).each do |response|
      answer = response.answer.to_s.strip
      break if kept.any? && kept.sum { |item| item[:answer].length } + answer.length > MAX_ANSWER_CHARS

      kept << { question: response.question.to_s.strip, answer: answer, score: (1.0 - response.neighbor_distance.to_f).round(2) }
    end
    kept
  end
end
