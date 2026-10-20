# frozen_string_literal: true

module Captain::Knowledge::Graph::LookupIntegration
  private

  def query_knowledge_graph(query, translated_query = nil)
    @knowledge_graph_cache ||= {}
    cache_key = [query.to_s, translated_query.to_s]
    @knowledge_graph_cache[cache_key] ||= Captain::Knowledge::Graph::SubgraphQueryService
                                          .new(account: account, assistant: assistant)
                                          .call(query: query, translated_query: translated_query)
  rescue StandardError => e
    Rails.logger.warn("[Captain::KnowledgeGraph] Lookup skipped: #{e.class}: #{e.message}")
    { matched: false, corroborated: false, evidence_responses: [] }
  end

  def rescue_with_knowledge_graph(query, translated_query, relevance_check)
    subgraph = query_knowledge_graph(query, translated_query)
    relevance_check[:graph_corroboration] = {
      matched: subgraph[:matched],
      corroborated: subgraph[:corroborated],
      matched_node_ids: Array(subgraph[:matched_nodes]).pluck(:id)
    }.compact
    return unless subgraph[:corroborated] && subgraph[:evidence_responses].present?

    relevance_check[:selection_passed] = true
    [subgraph[:evidence_responses].first(self.class::SEMANTIC_RESULT_LIMIT), relevance_check, 'graph_faq']
  end

  def enrich_responses_with_graph(responses, query:, translated_query: nil)
    subgraph = query_knowledge_graph(query, translated_query)
    return responses unless subgraph[:corroborated] && subgraph[:evidence_responses].present?

    (responses.to_a + subgraph[:evidence_responses]).uniq(&:id).first(self.class::SEMANTIC_RESULT_LIMIT)
  end

  def knowledge_graph_payload_for(query:, translated_query: nil)
    subgraph = query_knowledge_graph(query, translated_query)
    return unless subgraph[:matched]

    {
      corroborated: subgraph[:corroborated],
      matched_nodes: subgraph[:matched_nodes],
      connected_nodes: subgraph[:connected_nodes].presence,
      edges: subgraph[:edges].presence,
      verified_facts: subgraph[:verified_facts],
      conflicts: subgraph[:conflicts].presence
    }.compact
  end
end
