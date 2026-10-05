# == Schema Information
#
# Table name: scheduling_payments
#
#  id             :bigint           not null, primary key
#  amount         :integer          default(0), not null
#  payment_kind   :string           default("payment"), not null
#  payment_method :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  appointment_id :bigint           not null
#  recorded_by_id :bigint
#
# Indexes
#
#  idx_scheduling_payments_on_account_created_at      (account_id,created_at)
#  idx_scheduling_payments_on_appointment_adjustment  (appointment_id,payment_kind) UNIQUE WHERE ((payment_kind)::text = 'adjustment'::text)
#  idx_scheduling_payments_on_appointment_prepaid     (appointment_id,payment_kind) UNIQUE WHERE ((payment_kind)::text = 'prepaid'::text)
#  index_scheduling_payments_on_account_id            (account_id)
#  index_scheduling_payments_on_appointment_id        (appointment_id)
#  index_scheduling_payments_on_recorded_by_id        (recorded_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (appointment_id => scheduling_appointments.id)
#  fk_rails_...  (recorded_by_id => users.id)
#

class Scheduling::Payment < ApplicationRecord
  belongs_to :account
  belongs_to :appointment, class_name: 'Scheduling::Appointment', inverse_of: :payments
  belongs_to :recorded_by, class_name: 'User', optional: true
end
