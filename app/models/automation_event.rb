class AutomationEvent < ApplicationRecord
  STATUSES = %w[pending processing retrying completed dead].freeze
  IMMUTABLE_ATTRIBUTES = %w[
    account_id event_uuid dedupe_key event_name subject_type subject_id schema_version payload_snapshot changes_snapshot producer provenance
    trace_id causation_id depth created_at
  ].freeze

  belongs_to :account
  belongs_to :causation_event,
             class_name: 'AutomationEvent',
             foreign_key: :causation_id,
             primary_key: :event_uuid,
             optional: true,
             inverse_of: :caused_events
  has_many :caused_events,
           class_name: 'AutomationEvent',
           foreign_key: :causation_id,
           primary_key: :event_uuid,
           dependent: :restrict_with_exception,
           inverse_of: :causation_event
  has_many :automation_executions, dependent: :restrict_with_exception

  enum :status, STATUSES.index_with(&:itself), validate: true

  before_validation :assign_event_uuid, on: :create

  validates :event_uuid, :dedupe_key, :event_name, :subject_type, :subject_id, :producer, :trace_id, presence: true
  validates :event_uuid, uniqueness: true
  validates :dedupe_key, uniqueness: { scope: :account_id }
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }
  validates :depth, :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :lease_is_complete
  validate :dead_state_is_complete
  validate :causation_is_consistent
  validate :json_snapshots_have_expected_shapes
  validate :immutable_envelope, on: :update

  scope :ready, lambda {
    now = Time.current
    where(
      "(status IN ('pending', 'retrying') AND next_attempt_at <= :now) OR " \
      "(status = 'processing' AND lease_expires_at <= :now)",
      now: now
    ).order(Arel.sql("CASE WHEN status = 'processing' THEN lease_expires_at ELSE next_attempt_at END"), :id)
  }
  scope :expired_leases, -> { where(status: 'processing').where('lease_expires_at <= ?', Time.current).order(:lease_expires_at, :id) }
  scope :dead, -> { where(status: 'dead').order(dead_at: :desc, id: :desc) }

  private

  def assign_event_uuid
    self.event_uuid ||= SecureRandom.uuid
  end

  def lease_is_complete
    valid = status == 'processing' ? lease_owner.present? && lease_expires_at.present? : lease_owner.blank? && lease_expires_at.blank?
    return if valid

    errors.add(:lease_expires_at, 'must be present exactly while status is processing')
  end

  def dead_state_is_complete
    return if (status == 'dead') == dead_at.present?

    errors.add(:dead_at, 'must be present exactly when status is dead')
  end

  def causation_is_consistent
    return validate_root_causation if causation_event.blank?

    validate_child_causation
  end

  def validate_root_causation
    errors.add(:depth, 'must be zero for a root event') unless depth.zero?
    errors.add(:causation_id, 'must be blank for a root event') if causation_id.present?
  end

  def validate_child_causation
    errors.add(:causation_event, 'must belong to the same account') if causation_event.account_id != account_id
    errors.add(:trace_id, 'must match the causation event trace') if causation_event.trace_id != trace_id
    errors.add(:depth, 'must be one greater than the causation event depth') unless depth == causation_event.depth + 1
  end

  def json_snapshots_have_expected_shapes
    errors.add(:payload_snapshot, 'must be a non-empty object') unless payload_snapshot.is_a?(Hash) && payload_snapshot.present?
    errors.add(:changes_snapshot, 'must be an object') unless changes_snapshot.is_a?(Hash)
    errors.add(:provenance, 'must be a non-empty object') unless provenance.is_a?(Hash) && provenance.present?
  end

  def immutable_envelope
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Automation event envelope is immutable: #{changed.join(', ')}") if changed.any?
  end
end
