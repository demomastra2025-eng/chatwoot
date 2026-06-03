# frozen_string_literal: true

require 'timeout'

class Captain::Documents::Reranker
  DEFAULT_TOP_N = 5
  FALLBACK_REASON = 'rerank_unavailable'
  REQUEST_TIMEOUT_SECONDS = 8

  Result = Struct.new(:documents, :trace, keyword_init: true)

  def initialize(account:, model: nil)
    @account = account
    @model = model
  end

  def call(query:, documents:, top_n: DEFAULT_TOP_N)
    documents = Array(documents)
    top_n = normalized_top_n(top_n)
    return result(documents.first(top_n), disabled_trace) if documents.blank?

    model = rerank_model
    return result(documents.first(top_n), disabled_trace) if model.blank?

    response = rerank_response_for(query: query, documents: documents, model: model, top_n: top_n)

    ranked_documents = ranked_documents_for(response.results, documents, top_n)
    return degraded_result(documents, top_n, 'rerank_empty_result') if ranked_documents.blank?

    result(ranked_documents, success_trace(response, documents))
  rescue StandardError => e
    Rails.logger.warn do
      "#{self.class.name} unavailable for account #{account&.id}: #{e.class} - #{e.message}"
    end
    degraded_result(documents, top_n, FALLBACK_REASON, error_class: e.class.name)
  end

  private

  attr_reader :account, :model

  def rerank_response_for(query:, documents:, model:, top_n:)
    Timeout.timeout(REQUEST_TIMEOUT_SECONDS) do
      Llm::Runtime.rerank(
        feature: :knowledge_rerank,
        account: account,
        model: model,
        input: { query: query, documents: documents.map(&:content) },
        options: { top_n: top_n }
      )
    end
  end

  def rerank_model
    model.presence || Llm::Config.model_for(feature: 'knowledge_rerank', account: account, fallback: nil)
  end

  def ranked_documents_for(results, documents, top_n)
    ranked = []
    Array(results).each do |item|
      index = result_index(item)
      document = documents[index] if index.present? && index >= 0
      next if document.blank? || ranked.include?(document)

      ranked << document
      break if ranked.size >= top_n
    end
    ranked
  end

  def success_trace(response, documents)
    {
      attempted: true,
      enabled: true,
      degraded: false,
      model: response.respond_to?(:model) ? response.model : rerank_model,
      scores: score_trace(response.respond_to?(:results) ? response.results : [], documents)
    }.compact
  end

  def score_trace(results, documents)
    Array(results).filter_map do |item|
      index = result_index(item)
      document = documents[index] if index.present? && index >= 0
      next if document.blank?

      {
        document_chunk_id: document.id,
        relevance_score: result_score(item)
      }.compact
    end
  end

  def result_index(item)
    value = if item.is_a?(Hash)
              item[:index] || item['index']
            elsif item.respond_to?(:index)
              item.index
            end
    return if value.blank?

    value.to_i
  end

  def result_score(item)
    if item.is_a?(Hash)
      item[:relevance_score] || item['relevance_score'] || item[:score] || item['score']
    elsif item.respond_to?(:relevance_score)
      item.relevance_score
    end
  end

  def disabled_trace
    {
      attempted: false,
      enabled: false
    }
  end

  def degraded_result(documents, top_n, fallback_reason, error_class: nil)
    result(
      documents.first(top_n),
      {
        attempted: true,
        enabled: true,
        degraded: true,
        fallback_reason: fallback_reason,
        error_class: error_class
      }.compact
    )
  end

  def result(documents, trace)
    Result.new(documents: documents, trace: trace)
  end

  def normalized_top_n(value)
    top_n = value.to_i
    top_n.positive? ? top_n : DEFAULT_TOP_N
  end
end
