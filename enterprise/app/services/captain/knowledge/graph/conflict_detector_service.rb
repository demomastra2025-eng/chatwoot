# frozen_string_literal: true

class Captain::Knowledge::Graph::ConflictDetectorService
  WATCHED_FACT_KEYS = %w[available primary_price_kzt repeat_price_kzt accepts_children cabinet].freeze

  def self.detect_for_observations(observations)
    new.detect_for_observations(observations)
  end

  def self.scan_account(account, assistant_id: nil)
    scope = Captain::KnowledgeNode.where(account_id: account.id).visible_to_assistant(assistant_id)
    scope.filter_map do |node|
      next if node.conflicts.empty?

      {
        node_id: node.id,
        node_type: node.node_type,
        canonical_name: node.canonical_name,
        conflicts: node.conflicts
      }
    end
  end

  def detect_for_observations(observations)
    records = Array(observations).map(&:to_h)
    return [] if records.size < 2

    WATCHED_FACT_KEYS.filter_map do |fact_key|
      build_conflict_for_key(records, fact_key)
    end
  end

  private

  def build_conflict_for_key(records, fact_key)
    by_value = records.each_with_object({}) do |obs, acc|
      val = extract_fact_value(obs, fact_key)
      next if val.nil?

      (acc[val] ||= []) << {
        source_key: obs['source_key'],
        response_id: obs['response_id'],
        service_id: obs['service_id'],
        resource_id: obs['resource_id'],
        value: val
      }.compact
    end

    return if by_value.keys.size <= 1

    {
      'fact' => fact_key,
      'values' => by_value.keys,
      'sources' => by_value.values.flatten
    }
  end

  def extract_fact_value(obs, fact_key)
    attrs = obs['attributes'].to_h
    return attrs.dig('age_policy', 'accepts_children') if fact_key == 'accepts_children'

    attrs[fact_key]
  end
end
