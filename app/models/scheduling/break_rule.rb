# == Schema Information
#
# Table name: scheduling_break_rules
#
#  id           :bigint           not null, primary key
#  active       :boolean          default(TRUE), not null
#  end_minute   :integer          not null
#  start_minute :integer          not null
#  title        :string
#  weekday      :integer          not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  resource_id  :bigint           not null
#

class Scheduling::BreakRule < ApplicationRecord
  include Scheduling::MinuteRangeValidatable

  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :break_rules

  before_validation :sync_account_id

  validates :weekday, presence: true, inclusion: { in: 0..6 }
  validates :resource_id, uniqueness: { scope: [:weekday, :start_minute, :end_minute] }

  scope :ordered, -> { order(:weekday, :start_minute, :id) }
  scope :active, -> { where(active: true) }

  private

  def sync_account_id
    self.account_id = resource.account_id if resource.present?
  end
end
