# == Schema Information
#
# Table name: billing_plan_prices
#
#  id              :bigint           not null, primary key
#  amount_cents    :bigint           not null
#  currency        :string(3)        not null
#  interval        :string           not null
#  interval_count  :integer          default(1), not null
#  metadata        :jsonb            not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  billing_plan_id :bigint           not null
#
# Indexes
#
#  idx_billing_prices_unique_period              (billing_plan_id,currency,interval,interval_count) UNIQUE
#  index_billing_plan_prices_on_billing_plan_id  (billing_plan_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_plan_id => billing_plans.id)
#
class BillingPlanPrice < ApplicationRecord
  INTERVALS = %w[month year].freeze

  belongs_to :billing_plan
  has_many :subscriptions, class_name: 'BillingSubscription', dependent: :restrict_with_error

  enum :interval, INTERVALS.index_with(&:itself)

  validates :currency, presence: true, format: { with: /\A[A-Z]{3}\z/ }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :interval_count, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, uniqueness: { scope: [:billing_plan_id, :interval, :interval_count] }
  validate :metadata_is_object
  validate :commercial_terms_are_immutable, on: :update

  private

  def metadata_is_object
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end

  def commercial_terms_are_immutable
    attributes = %w[billing_plan_id currency amount_cents interval interval_count]
    return if attributes.none? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'price terms cannot be changed; create a new plan version')
  end
end
