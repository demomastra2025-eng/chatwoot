# == Schema Information
#
# Table name: scheduling_services
#
#  id                :bigint           not null, primary key
#  active            :boolean          default(TRUE), not null
#  base_price        :integer          default(0), not null
#  category          :string
#  custom_attributes :jsonb            not null
#  description       :text
#  direction         :string
#  duration_min      :integer          default(30), not null
#  name              :string           not null
#  service_type      :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#
# Indexes
#
#  idx_scheduling_services_account_medelement_code_unique  (account_id, ((custom_attributes ->> 'medelement_nomenclature_code'::text))) UNIQUE WHERE (NULLIF(btrim((custom_attributes ->> 'medelement_nomenclature_code'::text)), ''::text) IS NOT NULL)
#  idx_scheduling_services_on_account_active_name          (account_id,active,name)
#  index_scheduling_services_on_account_id                 (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#

class Scheduling::Service < ApplicationRecord
  belongs_to :account

  has_many :appointments, class_name: 'Scheduling::Appointment', dependent: :nullify, inverse_of: :service
  has_many :prices, class_name: 'Scheduling::ServicePrice', dependent: :destroy, inverse_of: :service

  validates :name, presence: true
  validates :base_price, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :duration_min, inclusion: { in: 5..720 }

  scope :ordered, -> { order(:name, :id) }
  scope :active, -> { where(active: true) }
end
