# frozen_string_literal: true

class Captain::Knowledge::Graph::SubgraphQueryService
  include Captain::Knowledge::Graph::Lexicon

  MAX_MATCHED_NODES = 6
  MAX_CONNECTED_NODES = 12
  MAX_EVIDENCE_RESPONSES = 5

  def initialize(account:, assistant: nil)
    @account = account
    @assistant = assistant
  end

  def call(query:, translated_query: nil)
    stems = Captain::Knowledge::Graph::Stemmer.extract_stems(query, translated_query)
    return empty_result if stems.empty?

    matched_nodes = find_matching_nodes(stems)
    return empty_result if matched_nodes.empty?

    build_subgraph_result(query, matched_nodes)
  end

  private

  def build_subgraph_result(query, matched_nodes)
    edges, connected_nodes = traverse_subgraph(matched_nodes)
    evidence_responses = load_visible_responses(collect_evidence_response_ids(matched_nodes, edges))

    {
      matched: true,
      corroborated: corroborated_by_graph?(query, matched_nodes, connected_nodes, edges),
      matched_nodes: matched_nodes.map { |node| serialize_node(node) },
      connected_nodes: connected_nodes.map { |node| serialize_node(node) },
      edges: edges.map { |edge| serialize_edge(edge) },
      verified_facts: build_verified_facts(matched_nodes, connected_nodes, edges),
      conflicts: collect_conflicts(matched_nodes + connected_nodes),
      evidence_response_ids: evidence_responses.map(&:id),
      evidence_responses: evidence_responses
    }
  end

  def find_matching_nodes(query_stems)
    candidates = Captain::KnowledgeNode.where(account_id: @account.id)
                                       .visible_to_assistant(@assistant&.id)
                                       .where('search_stems && ARRAY[?]::varchar[]', query_stems).to_a
    scored = candidates.filter_map { |node| score_candidate_node(node, query_stems) }
    scored.sort_by { |(node, score)| [-score, node.id] }.first(MAX_MATCHED_NODES).map(&:first)
  end

  def score_candidate_node(node, query_stems)
    overlap = Array(node.search_stems) & query_stems
    return if overlap.empty?

    node_coverage = overlap.size.to_f / [Array(node.search_stems).size, 1].max
    query_coverage = overlap.size.to_f / query_stems.size
    return unless strong_entity_match?(node, overlap, node_coverage, query_coverage)

    [node, (overlap.size * 2.0) + node_coverage + query_coverage]
  end

  def strong_entity_match?(node, overlap, node_coverage, query_coverage)
    return true if overlap.size >= 2
    return true if node.node_type.in?(%w[specialist specialty location]) && overlap.first.to_s.length >= 3

    node_coverage >= 0.34 || query_coverage >= 0.5
  end

  def corroborated_by_graph?(query, matched_nodes, connected_nodes, edges)
    raw_words = query.to_s.downcase.tr('ё', 'е').scan(/[\p{Alnum}]+/)
    return false if raw_words.intersect?(NEGATION_TOKENS) || !rich_graph_evidence?(matched_nodes, connected_nodes)

    meaningful_words = meaningful_query_words(raw_words)
    return false if meaningful_words.empty?

    verify_query_words(meaningful_words, matched_nodes + connected_nodes, edges)
  end

  def meaningful_query_words(raw_words)
    raw_words.reject { |w| QUERY_FILLER_WORDS.include?(w) || w.length < 3 || w.match?(/\A\d+\z/) }
  end

  def verify_query_words(words, all_nodes, edges)
    subgraph_stems = all_nodes.flat_map { |n| Array(n.search_stems) }.uniq
    combined_attrs = merge_subgraph_attributes(all_nodes)

    words.all? do |word|
      word_stems = Captain::Knowledge::Graph::Stemmer.extract_stems(word)
      word_stems.intersect?(subgraph_stems) || intent_satisfied?(word, combined_attrs, edges)
    end
  end

  def rich_graph_evidence?(matched_nodes, connected_nodes)
    return true if matched_nodes.any? { |n| n.node_type.in?(%w[specialist location symptom]) || n.source_type.present? }

    (matched_nodes + connected_nodes).any? do |node|
      attrs = node.attributes_data.to_h
      attrs['available'] == false || attrs.slice(*RICH_ATTR_KEYS).values.any?(&:present?)
    end
  end

  def merge_subgraph_attributes(nodes)
    nodes.each_with_object({}) do |node, acc|
      node.attributes_data.to_h.each { |k, v| acc[k] = v if v.present? || v == false }
    end
  end

  def intent_satisfied?(word, combined_attrs, edges)
    INTENT_RULES.each_value.any? { |rule| word.match?(rule[:pattern]) && rule[:check].call(combined_attrs, edges) }
  end

  def traverse_subgraph(matched_nodes)
    matched_ids = matched_nodes.map(&:id)
    edges = fetch_incident_edges(matched_ids)
    connected_nodes = fetch_connected_nodes(edges, matched_ids)
    visible_ids = (matched_ids + connected_nodes.map(&:id)).to_set
    filtered_edges = edges.select { |e| visible_ids.include?(e.source_node_id) && visible_ids.include?(e.target_node_id) }
    [filtered_edges, connected_nodes]
  end

  def fetch_incident_edges(matched_ids)
    Captain::KnowledgeEdge.where(account_id: @account.id)
                          .where('source_node_id IN (:ids) OR target_node_id IN (:ids)', ids: matched_ids)
                          .includes(:source_node, :target_node).to_a
  end

  def fetch_connected_nodes(edges, matched_ids)
    neighbor_ids = edges.flat_map { |e| [e.source_node_id, e.target_node_id] }.uniq - matched_ids
    Captain::KnowledgeNode.where(account_id: @account.id, id: neighbor_ids)
                          .visible_to_assistant(@assistant&.id).limit(MAX_CONNECTED_NODES).to_a
  end

  def collect_evidence_response_ids(matched_nodes, edges)
    counts = Hash.new(0)
    matched_nodes.each { |node| node.evidence_response_ids.each { |id| counts[id] += 3 } }
    edges.each { |edge| counts[edge.evidence_response_id] += 1 if edge.evidence_response_id.present? }
    counts.sort_by { |id, weight| [-weight, id] }.map(&:first).first(MAX_EVIDENCE_RESPONSES)
  end

  def load_visible_responses(response_ids)
    return [] if response_ids.empty?

    records = @account.captain_assistant_responses.approved.visible_to_assistant(@assistant&.id)
                      .where(id: response_ids).index_by(&:id)
    response_ids.filter_map { |id| records[id] }
  end

  def build_verified_facts(matched_nodes, connected_nodes, edges)
    node_map = (matched_nodes + connected_nodes).index_by(&:id)
    matched_nodes.map do |node|
      {
        entity_type: node.node_type, canonical_name: node.canonical_name,
        attributes: node.attributes_data, relations: build_node_relations(node, edges, node_map),
        conflicts: node.conflicts.presence
      }.compact
    end
  end

  def build_node_relations(node, edges, node_map)
    edges.select { |e| e.source_node_id == node.id || e.target_node_id == node.id }.filter_map do |edge|
      other = node_map[edge.source_node_id == node.id ? edge.target_node_id : edge.source_node_id]
      next unless other

      {
        relation: edge.relation_type, direction: edge.source_node_id == node.id ? 'outgoing' : 'incoming',
        entity_type: other.node_type, entity_name: other.canonical_name,
        attributes: other.attributes_data.presence, properties: edge.properties.presence
      }.compact
    end
  end

  def collect_conflicts(nodes)
    nodes.uniq(&:id).filter_map do |node|
      next if node.conflicts.empty?

      { node_id: node.id, node_type: node.node_type, canonical_name: node.canonical_name, conflicts: node.conflicts }
    end
  end

  def serialize_node(node)
    {
      id: node.id, type: node.node_type, canonical_name: node.canonical_name,
      aliases: node.aliases, attributes: node.attributes_data,
      evidence_response_ids: node.evidence_response_ids, conflicts: node.conflicts.presence
    }.compact
  end

  def serialize_edge(edge)
    {
      source_node_id: edge.source_node_id, source_name: edge.source_node.canonical_name,
      relation_type: edge.relation_type, target_node_id: edge.target_node_id,
      target_name: edge.target_node.canonical_name, evidence_response_id: edge.evidence_response_id,
      properties: edge.properties.presence
    }.compact
  end

  def empty_result
    {
      matched: false, corroborated: false, matched_nodes: [], connected_nodes: [],
      edges: [], verified_facts: [], conflicts: [], evidence_response_ids: [], evidence_responses: []
    }
  end
end
