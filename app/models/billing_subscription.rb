# frozen_string_literal: true

class BillingSubscription < ApplicationRecord
  STATUSES = %w[incomplete trialing active past_due grace_period suspended canceled].freeze
  ENTITLING_STATUSES = %w[trialing active past_due grace_period].freeze

  belongs_to :billing_account
  include Billing::ImmutableContract
  attr_readonly :billing_account_id, :billing_plan_id, :billing_plan_price_id, :plan_snapshot, :price_snapshot, :foundation_state

  validates :foundation_state, inclusion: { in: BillingAccount::STATES }
  validates :status, inclusion: { in: STATUSES }
  validate :complete_contract, if: :ready?
  validate :new_records_are_ready, on: :create

  scope :ready, -> { where(foundation_state: 'ready') }

  def ready?
    foundation_state == 'ready'
  end

  def readonly?
    super || (persisted? && !ready?)
  end

  private

  def complete_contract
    errors.add(:billing_account, 'must be ready') unless billing_account&.ready?
    errors.add(:base, 'new contracts do not use the retired plan catalogue') if billing_plan_id || billing_plan_price_id
    errors.add(:base, 'requires complete immutable plan and price snapshots') unless Billing::PlanSnapshot.valid?(plan_snapshot, price_snapshot)
  end

  def new_records_are_ready
    errors.add(:foundation_state, 'legacy_pending is reserved for pre-existing records') unless ready?
  end
end
