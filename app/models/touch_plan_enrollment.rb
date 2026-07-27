class TouchPlanEnrollment < ApplicationRecord
  STATUSES = %w[active paused completed cancelled].freeze
  SUPPORTED_REMINDABLE_TYPES = %w[Scheduling::Appointment Crm::Deal].freeze

  belongs_to :account
  belongs_to :reminder_group, optional: true
  belongs_to :remindable, polymorphic: true, optional: true

  has_many :touch_occurrence_claims, dependent: :destroy

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :plan_snapshot, presence: true
  validates :plan_digest, :activated_at, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validate :validate_account_boundaries
  validate :validate_remindable_type

  scope :due, ->(time = Time.current) { active.where(next_due_at: ..time) }
  scope :paused_by_feature, ->(feature_name) { paused.where("metadata ->> 'paused_reason' = ?", feature_name) }

  before_validation :normalize_json_fields

  def terminal?
    status.in?(%w[completed cancelled])
  end

  def cancel!(reason:, metadata: {})
    update!(
      status: 'cancelled',
      next_due_at: nil,
      metadata: self.metadata.merge(metadata.stringify_keys).merge('cancelled_reason' => reason, 'cancelled_at' => Time.current.iso8601)
    )
  end

  private

  def normalize_json_fields
    self.plan_snapshot = Array(plan_snapshot).map { |definition| Reminders::DefinitionNormalizer.call(definition) }
    self.metadata = (metadata || {}).to_h.stringify_keys
  end

  def validate_account_boundaries
    return if account.blank?

    errors.add(:remindable, 'must belong to the same account') if remindable.present? && remindable.account_id != account_id
    errors.add(:reminder_group, 'must belong to the same account') if reminder_group.present? && reminder_group.account_id != account_id
  end

  def validate_remindable_type
    return if remindable_type.blank? || SUPPORTED_REMINDABLE_TYPES.include?(remindable_type)

    errors.add(:remindable_type, 'is not supported for deferred touch materialization')
  end
end
