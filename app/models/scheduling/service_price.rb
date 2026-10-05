# == Schema Information
#
# Table name: scheduling_service_prices
#
#  id                   :bigint           not null, primary key
#  active               :boolean          default(TRUE), not null
#  compensation_percent :integer          default(0), not null
#  compensation_type    :string           default("percent"), not null
#  compensation_value   :integer          default(0), not null
#  price                :integer          default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  resource_id          :bigint           not null
#  service_id           :bigint           not null
#
# Indexes
#
#  idx_scheduling_service_prices_on_account_resource_active  (account_id,resource_id,active)
#  idx_scheduling_service_prices_on_service_resource         (service_id,resource_id) UNIQUE
#  index_scheduling_service_prices_on_account_id             (account_id)
#  index_scheduling_service_prices_on_resource_id            (resource_id)
#  index_scheduling_service_prices_on_service_id             (service_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#  fk_rails_...  (service_id => scheduling_services.id)
#

class Scheduling::ServicePrice < ApplicationRecord
  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :service_prices
  belongs_to :service, class_name: 'Scheduling::Service', inverse_of: :prices

  before_validation :sync_account_id

  validates :resource_id, uniqueness: { scope: :service_id }
  validates :price, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validate :resource_and_service_belong_to_same_account

  scope :ordered, -> { order(:resource_id, :id) }
  scope :active, -> { where(active: true) }

  private

  def resource_and_service_belong_to_same_account
    return unless resource.present? && service.present?
    return if resource.account_id == service.account_id

    errors.add(:resource_id, 'must belong to the same account as the service')
  end

  def sync_account_id
    self.account_id = service.account_id if service.present?
  end
end
