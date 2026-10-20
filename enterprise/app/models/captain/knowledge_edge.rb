# frozen_string_literal: true

class Captain::KnowledgeEdge < ApplicationRecord
  self.table_name = 'captain_knowledge_edges'

  RELATION_TYPES = %w[
    has_specialty
    performs_service
    located_in
    treats_symptom
    requires_preparation
    contraindicated_for
    alternative_for
  ].freeze

  belongs_to :account
  belongs_to :source_node, class_name: 'Captain::KnowledgeNode', inverse_of: :outgoing_edges
  belongs_to :target_node, class_name: 'Captain::KnowledgeNode', inverse_of: :incoming_edges
  belongs_to :evidence_response, class_name: 'Captain::AssistantResponse', optional: true
  belongs_to :evidence_document, class_name: 'Captain::Document', optional: true

  validates :relation_type, inclusion: { in: RELATION_TYPES }
end
