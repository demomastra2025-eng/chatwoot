class Integrations::Medelement::ScheduleDay < ApplicationRecord
  self.table_name = 'medelement_schedule_days'

  STATUSES = %w[confirmed empty_unconfirmed empty_confirmed unverified].freeze

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook'
  belongs_to :resource, class_name: 'Scheduling::Resource'

  validates :specialist_code, :date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :consecutive_empty_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :specialist_code, uniqueness: { scope: %i[hook_id date] }
  validate :same_account

  private

  def same_account
    return if account_id.blank? || hook.blank? || resource.blank?
    return if hook.account_id == account_id && resource.account_id == account_id

    errors.add(:account, 'must match hook and resource')
  end
end
