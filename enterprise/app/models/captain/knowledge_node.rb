# frozen_string_literal: true

class Captain::KnowledgeNode < ApplicationRecord
  self.table_name = 'captain_knowledge_nodes'

  NODE_TYPES = %w[specialist service specialty symptom location policy].freeze

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true

  has_many :outgoing_edges,
           class_name: 'Captain::KnowledgeEdge',
           foreign_key: :source_node_id,
           dependent: :destroy,
           inverse_of: :source_node
  has_many :incoming_edges,
           class_name: 'Captain::KnowledgeEdge',
           foreign_key: :target_node_id,
           dependent: :destroy,
           inverse_of: :target_node

  enum visibility: { general: 0, personal: 1 }, _prefix: :visibility

  validates :node_type, inclusion: { in: NODE_TYPES }
  validates :canonical_name, :normalized_key, presence: true

  scope :visible_to_assistant, lambda { |assistant_id|
    if assistant_id.present?
      where(visibility: visibilities[:general]).or(where(assistant_id: [nil, assistant_id]))
    else
      where(visibility: visibilities[:general], assistant_id: nil)
    end
  }

  def evidence_response_ids
    Array(metadata.to_h['evidence_response_ids']).map(&:to_i).uniq
  end

  def conflicts
    Array(metadata.to_h['conflicts'])
  end
end
