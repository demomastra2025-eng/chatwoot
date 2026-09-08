# == Schema Information
#
# Table name: billing_subscriptions
#
#  id                       :bigint           not null, primary key
#  cancel_at_period_end     :boolean          default(FALSE), not null
#  current_period_ends_at   :datetime
#  current_period_starts_at :datetime
#  metadata                 :jsonb            not null
#  plan_snapshot            :jsonb            not null
#  price_snapshot           :jsonb            not null
#  provider                 :string
#  status                   :string           default("incomplete"), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  billing_account_id       :bigint           not null
#  billing_plan_id          :bigint           not null
#  billing_plan_price_id    :bigint
#  external_id              :string
#
# Indexes
#
#  idx_billing_subscriptions_one_entitling               (billing_account_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['trialing'::character varying, 'active'::character varying, 'past_due'::character varying, 'grace_period'::character varying])::text[]))
#  idx_billing_subscriptions_provider_external           (provider,external_id) UNIQUE WHERE (external_id IS NOT NULL)
#  index_billing_subscriptions_on_billing_account_id     (billing_account_id)
#  index_billing_subscriptions_on_billing_plan_id        (billing_plan_id)
#  index_billing_subscriptions_on_billing_plan_price_id  (billing_plan_price_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_account_id => billing_accounts.id)
#  fk_rails_...  (billing_plan_id => billing_plans.id)
#  fk_rails_...  (billing_plan_price_id => billing_plan_prices.id)
#
class BillingSubscription < ApplicationRecord
  STATUSES = %w[incomplete trialing active past_due grace_period suspended canceled].freeze
  ENTITLING_STATUSES = %w[trialing active past_due grace_period].freeze
  IMMUTABLE_CATALOG_ATTRIBUTES = %w[billing_plan_id billing_plan_price_id plan_snapshot price_snapshot].freeze

  belongs_to :billing_account
  belongs_to :billing_plan
  belongs_to :billing_plan_price, optional: true
  has_many :entitlement_allocations, class_name: 'BillingEntitlementAllocation', dependent: :restrict_with_error

  enum :status, STATUSES.index_with(&:itself)

  scope :entitling, -> { where(status: ENTITLING_STATUSES) }

  validates :billing_account_id, uniqueness: { conditions: -> { where(status: ENTITLING_STATUSES) } },
                                 if: :entitling?
  validates :external_id, uniqueness: { scope: :provider }, allow_nil: true
  validate :price_belongs_to_plan
  validate :period_is_ordered
  validate :snapshots_are_objects
  validate :plan_is_subscribable, on: :create
  validate :catalog_contract_is_immutable, on: :update
  before_validation :capture_catalog_snapshots, on: :create

  def entitling?
    status.in?(ENTITLING_STATUSES)
  end

  private

  def capture_catalog_snapshots
    self.plan_snapshot = plan_snapshot_attributes if billing_plan.present? && plan_snapshot.blank?
    self.price_snapshot = price_snapshot_attributes if billing_plan_price.present? && price_snapshot.blank?
  end

  def plan_snapshot_attributes
    {
      'code' => billing_plan.code,
      'name' => billing_plan.name,
      'version' => billing_plan.version,
      'entitlements' => billing_plan.entitlements.deep_dup
    }
  end

  def price_snapshot_attributes
    {
      'currency' => billing_plan_price.currency,
      'amount_cents' => billing_plan_price.amount_cents,
      'interval' => billing_plan_price.interval,
      'interval_count' => billing_plan_price.interval_count
    }
  end

  def price_belongs_to_plan
    return if billing_plan_price.blank? || billing_plan_price.billing_plan_id == billing_plan_id

    errors.add(:billing_plan_price, 'must belong to the selected plan')
  end

  def period_is_ordered
    return if current_period_starts_at.blank? || current_period_ends_at.blank?
    return if current_period_ends_at > current_period_starts_at

    errors.add(:current_period_ends_at, 'must be after the period start')
  end

  def snapshots_are_objects
    errors.add(:plan_snapshot, 'must be an object') unless plan_snapshot.is_a?(Hash)
    errors.add(:price_snapshot, 'must be an object') unless price_snapshot.is_a?(Hash)
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end

  def plan_is_subscribable
    errors.add(:billing_plan, 'must be active') unless billing_plan&.active?
  end

  def catalog_contract_is_immutable
    return if IMMUTABLE_CATALOG_ATTRIBUTES.none? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'subscription catalog snapshots cannot be changed')
  end
end
