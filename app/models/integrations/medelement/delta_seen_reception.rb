class Integrations::Medelement::DeltaSeenReception < ApplicationRecord
  self.table_name = 'medelement_delta_seen_receptions'

  belongs_to :hook, class_name: 'Integrations::Hook'

  validates :reception_code, :change_marker, :processed_at, presence: true
end
