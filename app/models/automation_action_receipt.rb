class AutomationActionReceipt < ApplicationRecord
  STATUSES = %w[pending processing retrying succeeded skipped needs_attention].freeze
  IMMUTABLE_ATTRIBUTES = %w[account_id automation_execution_id action_id position action_signature created_at].freeze

  belongs_to :account
  belongs_to :automation_execution

  enum :status, STATUSES.index_with(&:itself), validate: true

  before_validation :assign_action_identity, on: :create

  validates :action_id, :action_signature, presence: true
  validates :action_id, uniqueness: { scope: :automation_execution_id }
  validates :position, uniqueness: { scope: :automation_execution_id }, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :execution_belongs_to_account
  validate :position_exists_in_execution_snapshot
  validate :action_identity_matches_execution_snapshot
  validate :lease_is_complete
  validate :attention_state_is_complete
  validate :immutable_identity, on: :update

  scope :ready, lambda {
    now = Time.current
    where(
      "(status IN ('pending', 'retrying') AND next_attempt_at <= :now) OR " \
      "(status = 'processing' AND lease_expires_at <= :now)",
      now: now
    ).order(Arel.sql("CASE WHEN status = 'processing' THEN lease_expires_at ELSE next_attempt_at END"), :id)
  }
  scope :expired_leases, -> { where(status: 'processing').where('lease_expires_at <= ?', Time.current).order(:lease_expires_at, :id) }

  private

  def assign_action_identity
    return if automation_execution.blank? || position.blank?

    self.action_id ||= automation_execution.action_identity_at(position)
    self.action_signature ||= automation_execution.action_signature_at(position)
  rescue IndexError
    nil
  end

  def execution_belongs_to_account
    return if automation_execution.blank? || automation_execution.account_id == account_id

    errors.add(:automation_execution, 'must belong to the same account')
  end

  def position_exists_in_execution_snapshot
    return if automation_execution.blank? || position.blank?
    return if position < automation_execution.actions_snapshot.length

    errors.add(:position, 'must reference an action in the immutable execution snapshot')
  end

  def action_identity_matches_execution_snapshot
    return if automation_execution.blank? || position.blank? || position >= automation_execution.actions_snapshot.length

    errors.add(:action_id, 'must match the immutable execution snapshot') if action_id != automation_execution.action_identity_at(position)
    return if action_signature == automation_execution.action_signature_at(position)

    errors.add(:action_signature, 'must match the immutable execution snapshot')
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

  def immutable_identity
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Automation action receipt identity is immutable: #{changed.join(', ')}") if changed.any?
  end
end
