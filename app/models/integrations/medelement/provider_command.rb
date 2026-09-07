# == Schema Information
#
# Table name: medelement_provider_commands
#
#  id                      :bigint           not null, primary key
#  attempt_count           :integer          default(0), not null
#  company_cabinet_code    :string
#  confirmed_at            :datetime
#  desired_ends_at         :datetime
#  desired_starts_at       :datetime
#  executed_at             :datetime
#  execution_state         :jsonb            not null
#  idempotency_key         :string           not null
#  last_error_code         :string
#  last_error_status       :integer
#  operation               :string           not null
#  provider_patient_code   :string
#  provider_reception_code :string
#  status                  :string           default("awaiting_confirmation"), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  appointment_id          :bigint
#  confirmation_request_id :bigint
#  contact_id              :bigint
#  hook_id                 :bigint
#  requested_by_id         :bigint
#
# Indexes
#
#  idx_medelement_commands_account_idempotency                    (account_id,idempotency_key) UNIQUE
#  idx_medelement_commands_appointment_status                     (appointment_id,status)
#  idx_medelement_commands_hook_status                            (hook_id,status)
#  idx_medelement_commands_unfinished_appointment                 (account_id,appointment_id) UNIQUE WHERE ((appointment_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['awaiting_confirmation'::character varying, 'awaiting_patient_selection'::character varying, 'awaiting_patient_creation'::character varying, 'awaiting_phone_refresh'::character varying, 'queued'::character varying, 'processing'::character varying, 'reconciliation_required'::character varying, 'v2_awaiting_confirmation'::character varying, 'v2_awaiting_patient_selection'::character varying, 'v2_awaiting_patient_creation'::character varying, 'v2_awaiting_phone_refresh'::character varying, 'v2_queued'::character varying, 'v2_processing'::character varying, 'v2_reconciliation_required'::character varying])::text[])))
#  idx_medelement_commands_unfinished_patient_identity            (account_id,contact_id) UNIQUE WHERE ((contact_id IS NOT NULL) AND (((operation)::text = ANY ((ARRAY['create_patient'::character varying, 'update_patient'::character varying])::text[])) OR (((operation)::text = 'create_reception'::text) AND ((provider_patient_code IS NULL) OR ((provider_patient_code)::text = ''::text)))) AND ((status)::text = ANY ((ARRAY['awaiting_confirmation'::character varying, 'awaiting_patient_selection'::character varying, 'awaiting_patient_creation'::character varying, 'awaiting_phone_refresh'::character varying, 'queued'::character varying, 'processing'::character varying, 'reconciliation_required'::character varying, 'v2_awaiting_confirmation'::character varying, 'v2_awaiting_patient_selection'::character varying, 'v2_awaiting_patient_creation'::character varying, 'v2_awaiting_phone_refresh'::character varying, 'v2_queued'::character varying, 'v2_processing'::character varying, 'v2_reconciliation_required'::character varying])::text[])))
#  index_medelement_provider_commands_on_account_id               (account_id)
#  index_medelement_provider_commands_on_appointment_id           (appointment_id)
#  index_medelement_provider_commands_on_confirmation_request_id  (confirmation_request_id)
#  index_medelement_provider_commands_on_contact_id               (contact_id)
#  index_medelement_provider_commands_on_hook_id                  (hook_id)
#  index_medelement_provider_commands_on_requested_by_id          (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (appointment_id => scheduling_appointments.id) ON DELETE => nullify
#  fk_rails_...  (confirmation_request_id => confirmation_requests.id) ON DELETE => nullify
#  fk_rails_...  (contact_id => contacts.id) ON DELETE => nullify
#  fk_rails_...  (hook_id => integrations_hooks.id) ON DELETE => nullify
#  fk_rails_...  (requested_by_id => users.id) ON DELETE => nullify
#
class Integrations::Medelement::ProviderCommand < ApplicationRecord
  self.table_name = 'medelement_provider_commands'

  OPERATIONS = %w[create_patient update_patient create_reception move_reception remove_reception].freeze
  LOGICAL_UNFINISHED_STATUSES = %w[
    awaiting_confirmation awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh
    queued processing reconciliation_required provider_status_unknown
  ].freeze
  TERMINAL_STATUSES = %w[succeeded failed declined cancelled].freeze
  EXECUTION_STATUS_PREFIX = 'v2_'.freeze
  VERSIONED_UNFINISHED_STATUSES = LOGICAL_UNFINISHED_STATUSES.map { |status| "#{EXECUTION_STATUS_PREFIX}#{status}" }.freeze
  STATUSES = (LOGICAL_UNFINISHED_STATUSES + VERSIONED_UNFINISHED_STATUSES + TERMINAL_STATUSES).freeze
  UNFINISHED_STATUSES = (LOGICAL_UNFINISHED_STATUSES + VERSIONED_UNFINISHED_STATUSES).freeze
  RECONCILIATION_MAX_ATTEMPTS = 6
  RECONCILIATION_BACKOFFS = [1.minute, 5.minutes, 15.minutes, 1.hour, 4.hours].freeze
  PROVIDER_STATUS_UNKNOWN_BACKOFF = 24.hours
  PATIENT_IDENTITY_WRITE_PREDICATE = <<~SQL.squish.freeze
    contact_id IS NOT NULL AND (
      operation IN ('create_patient', 'update_patient') OR
      (operation = 'create_reception' AND (provider_patient_code IS NULL OR provider_patient_code = ''))
    )
  SQL

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook', optional: true
  belongs_to :appointment, class_name: 'Scheduling::Appointment', optional: true
  belongs_to :contact, optional: true
  belongs_to :confirmation_request, optional: true
  belongs_to :requested_by, class_name: 'User', optional: true

  enum :operation, OPERATIONS.index_with(&:itself)
  enum :status, STATUSES.index_with(&:itself)

  validates :operation, :status, :idempotency_key, presence: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validate :associations_belong_to_account
  validate :hook_is_medelement
  validate :contact_matches_appointment
  validate :desired_range_for_move
  validate :company_cabinet_for_reception_write

  scope :executable, -> { where(status: execution_statuses('queued')) }
  scope :unfinished, -> { where(status: UNFINISHED_STATUSES) }
  scope :patient_identity_writes, -> { where(PATIENT_IDENTITY_WRITE_PREDICATE) }

  before_validation :normalize_execution_state
  before_validation :normalize_provider_patient_code

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def reconcilable?
    reconciliation_required? || provider_status_unknown?
  end

  def self.execution_statuses(logical_status)
    [logical_status.to_s, versioned_status(logical_status)]
  end

  def self.versioned_status(logical_status)
    "#{EXECUTION_STATUS_PREFIX}#{logical_status}"
  end

  def logical_status
    status.to_s.delete_prefix(EXECUTION_STATUS_PREFIX)
  end

  def versioned_execution?
    status.to_s.start_with?(EXECUTION_STATUS_PREFIX)
  end

  def status_for_transition(next_logical_status)
    normalized_status = next_logical_status.to_s
    return normalized_status if normalized_status.in?(TERMINAL_STATUSES)
    unless normalized_status.in?(LOGICAL_UNFINISHED_STATUSES)
      raise ArgumentError, "Unsupported Medelement provider command status: #{normalized_status}"
    end

    versioned_execution? ? self.class.versioned_status(normalized_status) : normalized_status
  end

  LOGICAL_UNFINISHED_STATUSES.each do |logical_status_name|
    define_method("#{logical_status_name}?") { logical_status == logical_status_name }
  end

  def reconciliation_attempts
    execution_state.to_h['reconciliation_attempts'].to_i
  end

  def reconciliation_next_at
    value = execution_state.to_h['reconciliation_next_at'].presence
    Time.iso8601(value) if value
  rescue ArgumentError
    nil
  end

  def request_snapshot
    execution_state.to_h['request_snapshot'].to_h
  end

  def request_snapshot_valid?
    stored_fingerprint = execution_state.to_h['request_fingerprint'].to_s
    computed_fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(request_snapshot)
    fingerprint_valid = request_snapshot.present? && fingerprints_match?(stored_fingerprint, computed_fingerprint)

    fingerprint_valid && request_snapshot_target_matches? &&
      Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.valid_schema?(request_snapshot)
  end

  def confirmation_matches_request_snapshot?(confirmation = confirmation_request)
    return false unless confirmation_binding_matches?(confirmation)

    fingerprints_match?(
      confirmation.metadata.to_h['request_fingerprint'].to_s,
      execution_state.to_h['request_fingerprint'].to_s
    )
  end

  private

  def confirmation_binding_matches?(confirmation)
    metadata = confirmation&.metadata.to_h
    confirmation.present? && confirmation.account_id == account_id &&
      confirmation.id == execution_state.to_h['confirmation_request_id'] &&
      metadata['medelement_provider_command_id'].to_s == id.to_s &&
      metadata['operation'].to_s == operation
  end

  def fingerprints_match?(first, second)
    first.present? && first.bytesize == second.bytesize && ActiveSupport::SecurityUtils.secure_compare(first, second)
  end

  def request_snapshot_target_matches?
    {
      'account_id' => account_id,
      'hook_id' => hook_id,
      'appointment_id' => appointment_id,
      'contact_id' => contact_id,
      'requested_by_id' => requested_by_id,
      'operation' => operation
    }.all? { |key, value| request_snapshot[key] == value }
  end

  def normalize_execution_state
    self.execution_state = execution_state.to_h if execution_state.blank? || execution_state.respond_to?(:to_h)
  end

  def normalize_provider_patient_code
    self.provider_patient_code = provider_patient_code.presence
  end

  def associations_belong_to_account
    {
      hook: hook,
      appointment: appointment,
      contact: contact,
      confirmation_request: confirmation_request,
      requested_by: requested_by
    }.each do |name, record|
      next if record.blank?
      next if record_belongs_to_account?(record)

      errors.add(name, 'must belong to the current account')
    end
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)

    record.respond_to?(:account_id) && record.account_id == account_id
  end

  def hook_is_medelement
    errors.add(:hook, 'must be a Medelement integration') if hook.present? && !hook.medelement?
  end

  def contact_matches_appointment
    return if appointment.blank? || appointment.contact_id == contact_id

    errors.add(:contact, 'must match the appointment contact')
  end

  def desired_range_for_move
    return unless move_reception?
    return if desired_starts_at.present? && desired_ends_at.present? && desired_ends_at > desired_starts_at

    errors.add(:desired_ends_at, 'must be after desired_starts_at for move_reception')
  end

  def company_cabinet_for_reception_write
    return unless create_reception? || move_reception?

    errors.add(:company_cabinet_code, 'is required') if company_cabinet_code.blank?
  end
end
