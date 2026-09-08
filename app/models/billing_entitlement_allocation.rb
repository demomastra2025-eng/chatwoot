# == Schema Information
#
# Table name: billing_entitlement_allocations
#
#  id                      :bigint           not null, primary key
#  ends_at                 :datetime
#  limits                  :jsonb            not null
#  metadata                :jsonb            not null
#  starts_at               :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :integer          not null
#  billing_subscription_id :bigint           not null
#
# Indexes
#
#  idx_billing_allocations_subscription                 (billing_subscription_id)
#  idx_billing_allocations_subscription_account         (billing_subscription_id,account_id) UNIQUE
#  index_billing_entitlement_allocations_on_account_id  (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (billing_subscription_id => billing_subscriptions.id)
#
class BillingEntitlementAllocation < ApplicationRecord
  belongs_to :billing_subscription
  belongs_to :account

  validates :account_id, uniqueness: { scope: :billing_subscription_id }
  validate :account_belongs_to_billing_account
  validate :limits_are_non_negative_numbers
  validate :period_is_ordered
  validate :metadata_is_object

  private

  def account_belongs_to_billing_account
    return if account.blank? || billing_subscription.blank?

    linked = BillingAccountWorkspace.exists?(
      billing_account_id: billing_subscription.billing_account_id || billing_subscription.billing_account&.id,
      account_id: account.id,
      status: 'active'
    )
    errors.add(:account, 'must be an active workspace of the billing account') unless linked
  end

  def limits_are_non_negative_numbers
    unless limits.is_a?(Hash)
      errors.add(:limits, 'must be an object')
      return
    end

    return if limits.values.all? { |limit| limit.is_a?(Numeric) && limit >= 0 }

    errors.add(:limits, 'must contain only non-negative numbers')
  end

  def period_is_ordered
    return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

    errors.add(:ends_at, 'must be after the start')
  end

  def metadata_is_object
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end
end
