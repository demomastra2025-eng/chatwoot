class Integrations::Medelement::DeltaMissCandidate < ApplicationRecord
  self.table_name = 'medelement_delta_miss_candidates'

  belongs_to :hook, class_name: 'Integrations::Hook'
  belongs_to :full_sweep_run, class_name: 'Integrations::Medelement::SyncRun', optional: true
end
