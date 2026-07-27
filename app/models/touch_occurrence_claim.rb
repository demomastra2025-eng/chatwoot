class TouchOccurrenceClaim < ApplicationRecord
  STATUSES = %w[claimed materialized skipped failed].freeze

  belongs_to :account
  belongs_to :touch_plan_enrollment
  belongs_to :reminder, optional: true

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :step_key, :occurrence_key, :due_at, :claimed_at, presence: true
  validates :occurrence_key, uniqueness: { scope: :touch_plan_enrollment_id }
  validate :validate_account_boundaries

  before_validation :normalize_metadata

  private

  def normalize_metadata
    self.metadata = (metadata || {}).to_h.stringify_keys
  end

  def validate_account_boundaries
    return if account.blank?

    if touch_plan_enrollment.present? && touch_plan_enrollment.account_id != account_id
      errors.add(:touch_plan_enrollment, 'must belong to the same account')
    end
    errors.add(:reminder, 'must belong to the same account') if reminder.present? && reminder.account_id != account_id
  end
end
