# == Schema Information
#
# Table name: scheduling_time_offs
#
#  id                :bigint           not null, primary key
#  custom_attributes :jsonb            not null
#  ends_at           :datetime         not null
#  kind              :string           not null
#  notes             :text
#  starts_at         :datetime         not null
#  title             :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  resource_id       :bigint
#
# Indexes
#
#  idx_scheduling_time_offs_on_account_resource_range  (account_id,resource_id,starts_at,ends_at)
#  index_scheduling_time_offs_on_account_id            (account_id)
#  index_scheduling_time_offs_on_resource_id           (resource_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#

class Scheduling::TimeOff < ApplicationRecord
  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :time_offs, optional: true

  before_validation :sync_account_id

  validates :kind, :starts_at, :ends_at, presence: true
  validate :ends_after_starts
  validate :resource_is_available_for_scheduling_setup

  scope :ordered, -> { order(:starts_at, :id) }

  private

  def ends_after_starts
    return if starts_at.blank? || ends_at.blank?
    return if ends_at > starts_at

    errors.add(:ends_at, 'must be after starts_at')
  end

  def resource_is_available_for_scheduling_setup
    return if resource.blank? || !resource.deleted_from_scheduling?

    errors.add(:resource_id, 'is not available for scheduling')
  end

  def sync_account_id
    self.account_id = resource.account_id if resource.present? && account_id.blank?
  end
end
