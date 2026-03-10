# == Schema Information
#
# Table name: scheduling_service_prices
#
#  id                 :bigint           not null, primary key
#  active             :boolean          default(TRUE), not null
#  compensation_type  :string           default("percent"), not null
#  compensation_value :integer          default(0), not null
#  price              :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  resource_id        :bigint           not null
#  service_id         :bigint           not null
#

class Scheduling::ServicePrice < ApplicationRecord
  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :service_prices
  belongs_to :service, class_name: 'Scheduling::Service', inverse_of: :prices

  before_validation :sync_account_id

  validates :resource_id, uniqueness: { scope: :service_id }
  validates :price, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :compensation_type, inclusion: { in: Scheduling::Constants::COMPENSATION_TYPES }
  validates :compensation_value, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validate :compensation_percent_within_range
  validate :active_price_requires_positive_amount
  validate :resource_and_service_belong_to_same_account

  scope :ordered, -> { order(:resource_id, :id) }
  scope :active, -> { where(active: true) }

  private

  def active_price_requires_positive_amount
    return unless active?
    return if price.to_i.positive?

    errors.add(:price, 'must be greater than 0 when the price is active')
  end

  def compensation_percent_within_range
    return unless compensation_type == 'percent'
    return if compensation_value.to_i.between?(0, 100)

    errors.add(:compensation_value, 'must be between 0 and 100 for percent compensation')
  end

  def resource_and_service_belong_to_same_account
    return unless resource.present? && service.present?
    return if resource.account_id == service.account_id

    errors.add(:resource_id, 'must belong to the same account as the service')
  end

  def sync_account_id
    self.account_id = service.account_id if service.present?
  end
end
