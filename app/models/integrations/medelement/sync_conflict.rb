# == Schema Information
#
# Table name: medelement_sync_conflicts
#
#  id                :bigint           not null, primary key
#  conflict_type     :string           not null
#  details           :jsonb            not null
#  entity_key_digest :string           not null
#  entity_type       :string           not null
#  fingerprint       :string           not null
#  first_seen_at     :datetime         not null
#  last_seen_at      :datetime         not null
#  occurrences       :integer          default(1), not null
#  phase             :string           not null
#  resolution_note   :text
#  resolved_at       :datetime
#  severity          :string           default("warning"), not null
#  status            :string           default("open"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  first_sync_run_id :bigint
#  hook_id           :bigint
#  last_sync_run_id  :bigint
#  resolved_by_id    :bigint
#
# Indexes
#
#  idx_medelement_sync_conflicts_account_fingerprint     (account_id,fingerprint) UNIQUE
#  idx_medelement_sync_conflicts_account_status          (account_id,status,last_seen_at)
#  idx_medelement_sync_conflicts_hook_phase_status       (hook_id,phase,status)
#  index_medelement_sync_conflicts_on_account_id         (account_id)
#  index_medelement_sync_conflicts_on_first_sync_run_id  (first_sync_run_id)
#  index_medelement_sync_conflicts_on_hook_id            (hook_id)
#  index_medelement_sync_conflicts_on_last_sync_run_id   (last_sync_run_id)
#  index_medelement_sync_conflicts_on_resolved_by_id     (resolved_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (first_sync_run_id => medelement_sync_runs.id) ON DELETE => nullify
#  fk_rails_...  (hook_id => integrations_hooks.id) ON DELETE => nullify
#  fk_rails_...  (last_sync_run_id => medelement_sync_runs.id) ON DELETE => nullify
#  fk_rails_...  (resolved_by_id => users.id) ON DELETE => nullify
#
class Integrations::Medelement::SyncConflict < ApplicationRecord
  self.table_name = 'medelement_sync_conflicts'

  STATUSES = %w[open ignored resolved].freeze
  SEVERITIES = %w[warning error].freeze

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook', optional: true
  belongs_to :first_sync_run, class_name: 'Integrations::Medelement::SyncRun', optional: true
  belongs_to :last_sync_run, class_name: 'Integrations::Medelement::SyncRun', optional: true, inverse_of: :observed_conflicts
  belongs_to :resolved_by, class_name: 'User', optional: true

  enum :status, STATUSES.index_with(&:itself)
  enum :severity, SEVERITIES.index_with(&:itself)

  validates :phase, inclusion: { in: Integrations::Medelement::SyncRun::PHASES }
  validates :entity_type, :conflict_type, :fingerprint, :entity_key_digest, presence: true
  validates :fingerprint, uniqueness: { scope: :account_id }

  scope :actionable, -> { where(status: %w[open ignored]).order(last_seen_at: :desc) }

  def ignore!(user:, note: 'Ignored by administrator')
    update!(status: 'ignored', resolved_by: user, resolved_at: Time.current, resolution_note: note)
  end

  def reopen!
    update!(status: 'open', resolved_by: nil, resolved_at: nil, resolution_note: nil)
  end

  def resolve_automatically!
    update!(
      status: 'resolved',
      resolved_by: nil,
      resolved_at: Time.current,
      resolution_note: 'Automatically resolved after a successful sync phase'
    )
  end

  def api_payload
    {
      id: id,
      phase: phase,
      entity_type: entity_type,
      conflict_type: conflict_type,
      severity: severity,
      status: status,
      details: details,
      occurrences: occurrences,
      first_seen_at: first_seen_at&.iso8601,
      last_seen_at: last_seen_at&.iso8601,
      resolved_at: resolved_at&.iso8601,
      resolution_note: resolution_note
    }
  end
end
