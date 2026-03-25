# == Schema Information
#
# Table name: scheduling_expenses
#
#  id             :bigint           not null, primary key
#  amount         :integer          default(0), not null
#  paid_at        :datetime
#  status         :string           default("unpaid"), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  appointment_id :bigint           not null
#  paid_by_id     :bigint
#  resource_id    :bigint           not null
#
# Indexes
#
#  idx_scheduling_expenses_on_account_status    (account_id,status)
#  index_scheduling_expenses_on_account_id      (account_id)
#  index_scheduling_expenses_on_appointment_id  (appointment_id) UNIQUE
#  index_scheduling_expenses_on_paid_by_id      (paid_by_id)
#  index_scheduling_expenses_on_resource_id     (resource_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (appointment_id => scheduling_appointments.id)
#  fk_rails_...  (paid_by_id => users.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#

class Scheduling::Expense < ApplicationRecord
  belongs_to :account
  belongs_to :appointment, class_name: 'Scheduling::Appointment', inverse_of: :expense
  belongs_to :paid_by, class_name: 'User', optional: true
  belongs_to :resource, class_name: 'Scheduling::Resource'

  before_validation :sync_account_id

  validates :amount, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :status, inclusion: { in: Scheduling::Constants::EXPENSE_STATUSES }
  validate :paid_by_belongs_to_account

  scope :ordered, -> { order(:created_at, :id) }

  private

  def paid_by_belongs_to_account
    return if paid_by_id.blank? || account.blank?
    return if account.users.exists?(id: paid_by_id)

    errors.add(:paid_by_id, 'must belong to the current account')
  end

  def sync_account_id
    self.account_id = appointment.account_id if appointment.present?
  end
end
