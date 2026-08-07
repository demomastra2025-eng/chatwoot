# == Schema Information
#
# Table name: touch_occurrence_claims
#
#  id                       :bigint           not null, primary key
#  claimed_at               :datetime         not null
#  due_at                   :datetime         not null
#  last_error               :text
#  materialized_at          :datetime
#  metadata                 :jsonb            not null
#  occurrence_key           :string           not null
#  status                   :string           default("claimed"), not null
#  step_key                 :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  reminder_id              :bigint
#  touch_plan_enrollment_id :bigint           not null
#
# Indexes
#
#  idx_touch_occurrence_claims_on_enrollment_occurrence       (touch_plan_enrollment_id,occurrence_key) UNIQUE
#  idx_touch_occurrence_claims_on_unique_reminder             (reminder_id) UNIQUE WHERE (reminder_id IS NOT NULL)
#  idx_touch_occurrence_claims_stale                          (status,claimed_at)
#  index_touch_occurrence_claims_on_account_id                (account_id)
#  index_touch_occurrence_claims_on_reminder_id               (reminder_id)
#  index_touch_occurrence_claims_on_touch_plan_enrollment_id  (touch_plan_enrollment_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (reminder_id => reminders.id)
#  fk_rails_...  (touch_plan_enrollment_id => touch_plan_enrollments.id)
#
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
