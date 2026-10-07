class Integrations::Medelement::DeltaMiss < ApplicationRecord
  self.table_name = 'medelement_delta_misses'

  KINDS = %w[created changed removed].freeze
  CLASSIFICATIONS = %w[own_api_change unexplained].freeze

  belongs_to :hook, class_name: 'Integrations::Hook'
  belongs_to :full_sweep_run, class_name: 'Integrations::Medelement::SyncRun', optional: true

  validates :reception_code, :change_marker, :detected_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :classification, inclusion: { in: CLASSIFICATIONS }
end
