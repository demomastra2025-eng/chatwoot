# rubocop:disable Layout/LineLength
# == Schema Information
#
# Table name: medelement_sync_runs
#
#  id               :bigint           not null, primary key
#  completed_at     :datetime
#  current_phase    :string
#  error_code       :string
#  error_message    :text
#  phase_results    :jsonb            not null
#  requested_phases :jsonb            not null
#  started_at       :datetime
#  status           :string           default("queued"), not null
#  summary          :jsonb            not null
#  trigger          :string           default("scheduled"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  hook_id          :bigint
#  requested_by_id  :bigint
#
# Indexes
#
#  idx_medelement_sync_runs_account_status        (account_id,status)
#  idx_medelement_sync_runs_hook_created          (hook_id,created_at)
#  idx_medelement_sync_runs_one_active_hook       (hook_id) UNIQUE WHERE ((hook_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying, 'retrying'::character varying])::text[])))
#  idx_medelement_sync_runs_terminal_completed    (completed_at) WHERE ((status)::text = ANY ((ARRAY['succeeded'::character varying, 'partial'::character varying, 'failed'::character varying])::text[]))
#  index_medelement_sync_runs_on_account_id       (account_id)
#  index_medelement_sync_runs_on_hook_id          (hook_id)
#  index_medelement_sync_runs_on_requested_by_id  (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (hook_id => integrations_hooks.id) ON DELETE => nullify
#  fk_rails_...  (requested_by_id => users.id) ON DELETE => nullify
#
# rubocop:enable Layout/LineLength
class Integrations::Medelement::SyncRun < ApplicationRecord
  InactiveRunError = Class.new(StandardError)
  self.table_name = 'medelement_sync_runs'

  PHASES = %w[setup specialists services contacts receptions].freeze
  STATUSES = %w[queued running retrying succeeded partial failed].freeze
  TERMINAL_STATUSES = %w[succeeded partial failed].freeze
  TRIGGERS = %w[manual scheduled retry].freeze

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook', optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  has_many :observed_conflicts,
           class_name: 'Integrations::Medelement::SyncConflict',
           foreign_key: :last_sync_run_id,
           dependent: :nullify,
           inverse_of: :last_sync_run

  enum :status, STATUSES.index_with(&:itself)

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validate :requested_phases_are_supported

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[queued running retrying]) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def phases
    requested_phases.presence || PHASES
  end

  def remaining_phases
    phases.reject { |phase| phase_results.dig(phase, 'status').in?(%w[succeeded skipped]) }
  end

  def start!
    update!(
      status: 'running',
      current_phase: nil,
      started_at: started_at || Time.current,
      completed_at: nil,
      error_code: nil,
      error_message: nil
    )
  end

  def start_phase!(phase)
    validate_phase!(phase)
    with_lock do
      reload
      raise InactiveRunError, 'Medelement sync run is no longer active' if terminal?

      update!(current_phase: phase)
    end
  end

  def heartbeat!
    with_lock do
      reload
      next false if terminal?

      update!(updated_at: Time.current)
      true
    end
  end

  def complete_phase!(phase, result = {})
    write_phase_result!(phase, result.to_h.merge(status: 'succeeded', completed_at: Time.current.iso8601))
  end

  def skip_phase!(phase, reason, skipped_count: 0)
    write_phase_result!(
      phase,
      status: 'skipped',
      reason: reason,
      skipped_count: skipped_count,
      completed_at: Time.current.iso8601
    )
  end

  def record_phase_failure!(phase, error)
    error_payload = Integrations::Medelement::ErrorSanitizer.exception_payload(error)
    write_phase_result!(phase, error_payload.merge(status: 'failed', completed_at: Time.current.iso8601))
    update!(
      current_phase: nil,
      error_code: error_payload[:code],
      error_message: error_payload[:message]
    )
  end

  def fail!(error)
    error_payload = Integrations::Medelement::ErrorSanitizer.exception_payload(error)
    with_lock do
      reload
      next if terminal?

      update!(
        status: 'failed',
        current_phase: nil,
        completed_at: Time.current,
        error_code: error_payload[:code],
        error_message: error_payload[:message]
      )
    end
  end

  def retry!(error)
    error_payload = Integrations::Medelement::ErrorSanitizer.exception_payload(error)
    with_lock do
      reload
      next if terminal?

      update!(
        status: 'retrying',
        current_phase: nil,
        completed_at: nil,
        error_code: error_payload[:code],
        error_message: error_payload[:message]
      )
    end
  end

  def finish!
    with_lock do
      reload
      next if terminal?

      open_conflicts = conflict_scope.open.count
      skipped = phase_results.values.sum { |result| result.to_h['skipped_count'].to_i }
      final_status = open_conflicts.positive? || skipped.positive? ? 'partial' : 'succeeded'

      update!(
        status: final_status,
        current_phase: nil,
        completed_at: Time.current,
        summary: summary.merge(
          open_conflicts: open_conflicts,
          ignored_conflicts: conflict_scope.ignored.count,
          skipped_count: skipped
        )
      )
    end
  end

  def api_payload
    {
      id: id,
      trigger: trigger,
      status: status,
      current_phase: current_phase,
      requested_phases: phases,
      phase_results: phase_results,
      summary: summary,
      error_code: error_code,
      error_message: error_message,
      started_at: started_at&.iso8601,
      completed_at: completed_at&.iso8601,
      created_at: created_at.iso8601
    }
  end

  private

  def conflict_scope
    Integrations::Medelement::SyncConflict.where(
      account_id: account_id,
      hook_id: hook_id,
      phase: phases
    )
  end

  def requested_phases_are_supported
    values = Array(requested_phases)
    return if values.all? { |phase| phase.in?(PHASES) }

    errors.add(:requested_phases, 'contains unsupported phases')
  end

  def validate_phase!(phase)
    raise ArgumentError, "Unsupported Medelement sync phase: #{phase}" unless phase.to_s.in?(PHASES)
  end

  def write_phase_result!(phase, result)
    validate_phase!(phase)
    with_lock do
      reload
      raise InactiveRunError, 'Medelement sync run is no longer active' if terminal?

      update!(phase_results: phase_results.merge(phase.to_s => result.deep_stringify_keys))
    end
  end
end
