# == Schema Information
#
# Table name: scheduling_holidays
#
#  id                   :bigint           not null, primary key
#  custom_attributes    :jsonb            not null
#  date                 :date             not null
#  recurring_yearly     :boolean          default(FALSE), not null
#  title                :string           not null
#  working_day_override :boolean          default(FALSE), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#

class Scheduling::Holiday < ApplicationRecord
  belongs_to :account

  validates :date, :title, presence: true

  scope :ordered, -> { order(:date, :title, :id) }
end
