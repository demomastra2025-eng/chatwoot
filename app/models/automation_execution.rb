class AutomationExecution < ApplicationRecord
  STATUSES = %w[pending scheduled processing retrying succeeded cancelled needs_attention].freeze
  IMMUTABLE_ATTRIBUTES = %w[
    account_id automation_event_id automation_rule_id automation_rule_group_id lifecycle_generation definition_version schema_version
    conditions_snapshot actions_snapshot execution_schedule_snapshot scheduled_at created_at
  ].freeze

  belongs_to :account
  belongs_to :automation_event
  belongs_to :automation_rule
  belongs_to :automation_rule_group, optional: true
  has_many :automation_action_receipts, dependent: :restrict_with_exception

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :lifecycle_generation, :definition_version, :schema_version,
            numericality: { only_integer: true, greater_than: 0 }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :scheduled_at, presence: true
  validate :associations_belong_to_account
  validate :group_matches_rule
  validate :snapshots_have_expected_shapes
  validate :lease_is_complete
  validate :attention_state_is_complete
  validate :immutable_snapshot, on: :update

  scope :ready, lambda {
    now = Time.current
    where(
      "(status IN ('pending', 'scheduled', 'retrying') AND next_attempt_at <= :now) OR " \
      "(status = 'processing' AND lease_expires_at <= :now)",
      now: now
    ).order(Arel.sql("CASE WHEN status = 'processing' THEN lease_expires_at ELSE next_attempt_at END"), :id)
  }
  scope :expired_leases, -> { where(status: 'processing').where('lease_expires_at <= ?', Time.current).order(:lease_expires_at, :id) }

  def action_at(position)
    actions_snapshot.fetch(position).to_h.with_indifferent_access
  end

  def action_identity_at(position)
    action_at(position)[:action_id].presence || "legacy-index:#{position}"
  end

  def action_signature_at(position)
    quoted_action = self.class.connection.quote(action_at(position).to_json)
    self.class.connection.select_value("SELECT automation_action_signature(#{quoted_action}::jsonb)")
  end

  private

  def associations_belong_to_account
    {
      automation_event: automation_event,
      automation_rule: automation_rule,
      automation_rule_group: automation_rule_group
    }.each do |attribute, record|
      next if record.blank? || record.account_id == account_id

      errors.add(attribute, 'must belong to the same account')
    end
  end

  def group_matches_rule
    return if automation_rule.blank? || automation_rule_group_id == automation_rule.automation_rule_group_id

    errors.add(:automation_rule_group, 'must match the selected rule group')
  end

  def snapshots_have_expected_shapes
    errors.add(:conditions_snapshot, 'must be an array') unless conditions_snapshot.is_a?(Array)
    validate_actions_snapshot
    errors.add(:execution_schedule_snapshot, 'must be an object') unless execution_schedule_snapshot.is_a?(Hash)
  end

  def validate_actions_snapshot
    unless valid_actions_snapshot_collection?
      errors.add(:actions_snapshot, 'must be a non-empty array of objects')
      return
    end

    explicit_ids = explicit_action_ids
    unless explicit_ids.all? { |action_id| action_id.is_a?(String) && action_id.present? }
      errors.add(:actions_snapshot, 'must use non-blank string explicit action ids')
    end
    errors.add(:actions_snapshot, 'must use unique explicit action ids') if explicit_ids.compact.uniq.length != explicit_ids.compact.length
  end

  def valid_actions_snapshot_collection?
    actions_snapshot.is_a?(Array) && actions_snapshot.any? && actions_snapshot.all?(Hash)
  end

  def explicit_action_ids
    actions_snapshot
      .select { |action| action.key?('action_id') || action.key?(:action_id) }
      .map { |action| action.with_indifferent_access[:action_id] }
  end

  def lease_is_complete
    valid = status == 'processing' ? lease_owner.present? && lease_expires_at.present? : lease_owner.blank? && lease_expires_at.blank?
    return if valid

    errors.add(:lease_expires_at, 'must be present exactly while status is processing')
  end

  def attention_state_is_complete
    return if (status == 'needs_attention') == needs_attention_at.present?

    errors.add(:needs_attention_at, 'must be present exactly when status needs attention')
  end

  def immutable_snapshot
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Automation execution snapshot is immutable: #{changed.join(', ')}") if changed.any?
  end
end
