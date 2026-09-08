require 'rails_helper'

RSpec.describe Billing::EntitlementResolver do
  subject(:resolver) do
    described_class.new(account: account, at: now, legacy_metadata: legacy_metadata)
  end

  let(:account) { create(:account) }
  let(:now) { Time.zone.parse('2026-09-04 12:00:00') }
  let(:legacy_metadata) do
    lambda do |key|
      { value: key == 'agents' ? 3 : 1.gigabyte, unlimited: false }
    end
  end

  it 'resolves an allocated limit from the current billing subscription' do
    subscription = create_current_subscription
    create(
      :billing_entitlement_allocation,
      billing_subscription: subscription,
      account: account,
      limits: { 'agents' => 12 },
      starts_at: 1.day.before(now),
      ends_at: 1.day.after(now)
    )

    expect(resolver.resolve(:agents)).to have_attributes(value: 12, unlimited: false, source: :billing_allocation)
  end

  it 'falls back per key when the allocation does not define that entitlement' do
    subscription = create_current_subscription
    create(
      :billing_entitlement_allocation,
      billing_subscription: subscription,
      account: account,
      limits: { 'agents' => 12 }
    )

    expect(resolver.resolve(:storage_bytes)).to have_attributes(
      value: 1.gigabyte,
      unlimited: false,
      source: :legacy
    )
  end

  it 'falls back when the workspace link is detached' do
    subscription = create_current_subscription
    create(:billing_entitlement_allocation, billing_subscription: subscription, account: account, limits: { 'agents' => 12 })
    subscription.billing_account.workspace_links.find_by!(account: account).update!(status: 'detached', detached_at: 1.hour.before(now))

    expect(resolver.resolve(:agents)).to have_attributes(value: 3, source: :legacy)
  end

  it 'falls back when the allocation is outside its effective period' do
    subscription = create_current_subscription
    create(
      :billing_entitlement_allocation,
      billing_subscription: subscription,
      account: account,
      limits: { 'agents' => 12 },
      ends_at: 1.second.before(now)
    )

    expect(resolver.resolve(:agents)).to have_attributes(value: 3, source: :legacy)
  end

  it 'falls back when the subscription is not entitlement-bearing' do
    subscription = create_current_subscription(subscription_status: 'suspended')
    create(:billing_entitlement_allocation, billing_subscription: subscription, account: account, limits: { 'agents' => 12 })

    expect(resolver.resolve(:agents)).to have_attributes(value: 3, source: :legacy)
  end

  private

  def create_current_subscription(subscription_status: 'active')
    billing_account = create(:billing_account)
    create(:billing_account_workspace, billing_account: billing_account, account: account)
    create(:billing_subscription, billing_account: billing_account, status: subscription_status)
  end
end
