class Integrations::Medelement::ProviderCommand < ApplicationRecord
  self.table_name = 'medelement_provider_commands'

  OPERATIONS = %w[create_patient update_patient create_reception move_reception remove_reception].freeze
  STATUSES = %w[
    awaiting_confirmation queued processing succeeded failed reconciliation_required declined cancelled
  ].freeze
  TERMINAL_STATUSES = %w[succeeded failed declined cancelled].freeze
  RECONCILIATION_MAX_ATTEMPTS = 6
  RECONCILIATION_BACKOFFS = [1.minute, 5.minutes, 15.minutes, 1.hour, 4.hours].freeze
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

  scope :executable, -> { where(status: 'queued') }
  scope :unfinished, -> { where.not(status: TERMINAL_STATUSES) }
  scope :patient_identity_writes, -> { where(PATIENT_IDENTITY_WRITE_PREDICATE) }

  before_validation :normalize_execution_state
  before_validation :normalize_provider_patient_code

  def terminal?
    status.in?(TERMINAL_STATUSES)
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

    fingerprint_valid && request_snapshot_target_matches?
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
