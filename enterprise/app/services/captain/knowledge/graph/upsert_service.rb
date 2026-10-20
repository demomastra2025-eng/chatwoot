# frozen_string_literal: true

class Captain::Knowledge::Graph::UpsertService
  def initialize(account:, assistant_id: nil, visibility: :general)
    @account = account
    @assistant_id = assistant_id
    @visibility = visibility
  end

  def upsert_node(node_type:, canonical_name:, source_key:, **options)
    normalized_key = Captain::Knowledge::Graph::Stemmer.normalize_key(canonical_name)
    return if normalized_key.blank?

    node = find_or_build_node(node_type, normalized_key)
    apply_node_attributes!(node, canonical_name, options)
    merge_observation!(
      node,
      source_key: source_key,
      response_id: options[:response_id],
      attributes: options[:attributes].to_h.deep_stringify_keys
    )
    node.save!
    node
  end

  def upsert_edge(source_node:, target_node:, relation_type:, response_id: nil, properties: {})
    return if source_node.blank? || target_node.blank? || source_node.id == target_node.id

    edge = Captain::KnowledgeEdge.find_or_initialize_by(
      account_id: @account.id,
      source_node_id: source_node.id,
      target_node_id: target_node.id,
      relation_type: relation_type.to_s,
      evidence_response_id: response_id
    )
    edge.properties = edge.properties.to_h.merge(properties.to_h.deep_stringify_keys)
    edge.save!
    edge
  end

  def remove_response_evidence!(response_id)
    Captain::KnowledgeEdge.where(account_id: @account.id, evidence_response_id: response_id).delete_all
    source_key = "faq:#{response_id}"

    Captain::KnowledgeNode.where(account_id: @account.id).find_each do |node|
      prune_node_observation!(node, response_id.to_i, source_key)
    end
  end

  private

  def find_or_build_node(node_type, normalized_key)
    Captain::KnowledgeNode.find_or_initialize_by(
      account_id: @account.id,
      node_type: node_type.to_s,
      normalized_key: normalized_key
    )
  end

  def apply_node_attributes!(node, canonical_name, options)
    node.assistant_id = @assistant_id if node.new_record?
    node.visibility = :general if @visibility.to_s == 'general' || node.new_record?
    node.canonical_name = canonical_name if node.new_record? || canonical_name.length > node.canonical_name.to_s.length
    node.aliases = normalized_aliases(node.aliases, options[:aliases], canonical_name)
    node.search_stems = Captain::Knowledge::Graph::Stemmer.extract_stems(node.canonical_name, node.aliases)
    assign_source_reference!(node, options[:source_type], options[:source_id])
  end

  def normalized_aliases(existing, incoming, canonical_name)
    (Array(existing) + Array(incoming) + [canonical_name]).map(&:to_s).map(&:squish).reject(&:blank?).uniq
  end

  def assign_source_reference!(node, source_type, source_id)
    return if source_type.blank? || source_id.blank?

    node.source_type = source_type
    node.source_id = source_id
  end

  def prune_node_observation!(node, response_id, source_key)
    meta = node.metadata.to_h.deep_dup
    obs = Array(meta['source_observations']).reject { |item| item['source_key'] == source_key || item['response_id'] == response_id }
    ids = Array(meta['evidence_response_ids']).map(&:to_i) - [response_id]

    if obs.empty? && ids.empty? && node.source_type.blank?
      node.destroy!
    else
      rebuild_node_from_observations!(node, obs, ids)
      node.save!
    end
  end

  def merge_observation!(node, source_key:, response_id:, attributes:)
    meta = node.metadata.to_h.deep_dup
    observations = Array(meta['source_observations']).reject { |item| item['source_key'] == source_key }
    observations << { 'source_key' => source_key, 'response_id' => response_id, 'attributes' => attributes.compact }.compact
    ids = (Array(meta['evidence_response_ids']) + [response_id]).compact.map(&:to_i).uniq
    rebuild_node_from_observations!(node, observations, ids)
  end

  def rebuild_node_from_observations!(node, observations, evidence_ids)
    merged_attrs = observations.each_with_object({}) do |obs, acc|
      obs['attributes'].to_h.each do |k, v|
        acc[k] = v unless v.nil? || (v.respond_to?(:empty?) && v.empty?)
      end
    end
    conflicts = Captain::Knowledge::Graph::ConflictDetectorService.detect_for_observations(observations)
    node.attributes_data = merged_attrs
    node.metadata = node.metadata.to_h.merge(
      'source_observations' => observations,
      'evidence_response_ids' => evidence_ids,
      'conflicts' => conflicts
    )
  end
end
