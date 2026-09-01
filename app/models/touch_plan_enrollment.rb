# == Schema Information
#
# Table name: touch_plan_enrollments
#
#  id                 :bigint           not null, primary key
#  activated_at       :datetime         not null
#  idempotency_key    :string           not null
#  metadata           :jsonb            not null
#  next_due_at        :datetime
#  plan_digest        :string           not null
#  plan_snapshot      :jsonb            not null
#  remindable_type    :string
#  status             :string           default("active"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  automation_rule_id :bigint
#  remindable_id      :bigint
#  reminder_group_id  :bigint
#  source_action_id   :string
#  source_generation  :bigint
#
# Indexes
#
#  idx_touch_plan_enrollments_due                      (status,next_due_at)
#  idx_touch_plan_enrollments_on_account_idempotency   (account_id,idempotency_key) UNIQUE
#  idx_touch_plan_enrollments_on_remindable_status     (remindable_type,remindable_id,status)
#  idx_touch_plan_enrollments_one_open_action_generation  (account_id,automation_rule_id,source_generation,source_action_id,remindable_type,remindable_id) UNIQUE WHERE (((status)::text = ANY ((ARRAY['active'::character varying, 'paused'::character varying, 'completed'::character varying])::text[])) AND (automation_rule_id IS NOT NULL))
#  idx_touch_plan_enrollments_one_open_plan            (account_id,reminder_group_id,remindable_type,remindable_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['active'::character varying, 'paused'::character varying])::text[]))
#  index_touch_plan_enrollments_on_account_id          (account_id)
#  index_touch_plan_enrollments_on_automation_rule_id  (automation_rule_id)
#  index_touch_plan_enrollments_on_remindable          (remindable_type,remindable_id)
#  index_touch_plan_enrollments_on_reminder_group_id   (reminder_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (automation_rule_id => automation_rules.id)
#  fk_rails_...  (reminder_group_id => reminder_groups.id)
#
class TouchPlanEnrollment < ApplicationRecord
  STATUSES = %w[active paused completed cancelled].freeze
  SUPPORTED_REMINDABLE_TYPES = %w[Scheduling::Appointment Crm::Deal].freeze

  belongs_to :account
  belongs_to :reminder_group, optional: true
  belongs_to :automation_rule, optional: true
  belongs_to :remindable, polymorphic: true, optional: true

  has_many :touch_occurrence_claims, dependent: :destroy

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :plan_snapshot, presence: true
  validates :plan_digest, :activated_at, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validates :source_generation, presence: true, if: :automation_rule_id?
  validate :validate_live_source
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
    errors.add(:automation_rule, 'must belong to the same account') if automation_rule.present? && automation_rule.account_id != account_id
  end

  def validate_live_source
    source_count = [reminder_group_id, automation_rule_id].compact.size
    return if cancelled? && source_count.zero?

    errors.add(:base, 'must have exactly one live source') unless source_count == 1
    return if automation_rule_id.blank? || source_action_id.present?

    errors.add(:source_action_id, 'must be present for an automation source')
  end

  def validate_remindable_type
    return if remindable_type.blank? || SUPPORTED_REMINDABLE_TYPES.include?(remindable_type)

    errors.add(:remindable_type, 'is not supported for deferred touch materialization')
  end
end
