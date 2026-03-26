# == Schema Information
#
# Table name: scheduling_workday_overrides
#
#  id                 :bigint           not null, primary key
#  break_end_minute   :integer
#  break_start_minute :integer
#  break_title        :string
#  custom_attributes  :jsonb            not null
#  date               :date             not null
#  end_minute         :integer          not null
#  start_minute       :integer          not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  resource_id        :bigint           not null
#
# Indexes
#
#  idx_scheduling_workday_overrides_on_account_date   (account_id,date)
#  idx_scheduling_workday_overrides_on_resource_date  (resource_id,date) UNIQUE
#  index_scheduling_workday_overrides_on_account_id   (account_id)
#  index_scheduling_workday_overrides_on_resource_id  (resource_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#

class Scheduling::WorkdayOverride < ApplicationRecord
  include Scheduling::MinuteRangeValidatable

  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :workday_overrides

  before_validation :sync_account_id

  validates :date, presence: true, uniqueness: { scope: :resource_id }
  validate :break_interval_is_valid
  validate :resource_is_available_for_scheduling_setup

  scope :ordered, -> { order(:date, :resource_id, :id) }

  private

  def break_interval_is_valid
    has_break_start = break_start_minute.present?
    has_break_end = break_end_minute.present?
    return unless has_break_start || has_break_end

    unless has_break_start && has_break_end
      errors.add(:base, 'break_start_minute and break_end_minute must be provided together')
      return
    end

    unless break_start_minute.to_i.between?(start_minute.to_i, end_minute.to_i - 1) &&
           break_end_minute.to_i.between?(start_minute.to_i + 1, end_minute.to_i)
      errors.add(:base, 'break interval must be inside the override range')
      return
    end

    return if break_end_minute.to_i > break_start_minute.to_i

    errors.add(:break_end_minute, 'must be greater than break_start_minute')
  end

  def resource_is_available_for_scheduling_setup
    return if resource.blank? || !resource.deleted_from_scheduling?

    errors.add(:resource_id, 'is not available for scheduling')
  end

  def sync_account_id
    self.account_id = resource.account_id if resource.present?
  end
end
