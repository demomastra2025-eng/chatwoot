require 'rails_helper'

RSpec.describe BillingAccount do
  describe BillingAccount do
    it 'accepts a provider-neutral payer account' do
      billing_account = build(:billing_account)

      expect(billing_account).to be_valid
    end

    it 'requires an ISO-style uppercase currency code' do
      billing_account = build(:billing_account, default_currency: 'kzt')

      expect(billing_account).not_to be_valid
      expect(billing_account.errors[:default_currency]).to be_present
    end

    it 'exposes only active members and attached workspaces' do
      billing_account = create(:billing_account)
      active_user = create(:user)
      create(:billing_account_membership, billing_account: billing_account, user: active_user)
      create(:billing_account_membership, billing_account: billing_account, status: 'inactive')
      active_workspace = create(:account)
      create(:billing_account_workspace, billing_account: billing_account, account: active_workspace)
      create(:billing_account_workspace, billing_account: billing_account, status: 'detached', detached_at: Time.current)

      expect(billing_account.users).to contain_exactly(active_user)
      expect(billing_account.workspaces).to contain_exactly(active_workspace)
    end
  end

  describe BillingAccountMembership do
    it 'allows only one active owner per billing account' do
      billing_account = create(:billing_account)
      create(:billing_account_membership, billing_account: billing_account, role: 'owner')

      duplicate_owner = build(:billing_account_membership, billing_account: billing_account, role: 'owner')

      expect(duplicate_owner).not_to be_valid
      expect(duplicate_owner.errors[:role]).to include('already has an active owner')
    end

    it 'keeps workspace administration separate from billing roles' do
      membership = build(:billing_account_membership, role: 'billing_admin')

      expect(membership).to be_valid
      expect(membership.role).to eq('billing_admin')
    end

    it 'does not block normal user deletion' do
      membership = create(:billing_account_membership)

      expect { membership.user.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe BillingAccountWorkspace do
    it 'prevents one workspace from joining two active billing accounts' do
      account = create(:account)
      create(:billing_account_workspace, account: account)

      duplicate_link = build(:billing_account_workspace, account: account)

      expect(duplicate_link).not_to be_valid
      expect(duplicate_link.errors[:account_id]).to be_present
    end

    it 'preserves detached workspace history' do
      account = create(:account)
      create(:billing_account_workspace, account: account, status: 'detached', detached_at: Time.current)

      expect(build(:billing_account_workspace, account: account)).to be_valid
    end

    it 'does not block normal workspace deletion' do
      workspace_link = create(:billing_account_workspace)

      expect { workspace_link.account.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe BillingPlan do
    it 'versions plans without changing their stable code' do
      create(:billing_plan, code: 'growth', version: 1)

      expect(build(:billing_plan, code: 'growth', version: 2)).to be_valid
      expect(build(:billing_plan, code: 'growth', version: 1)).not_to be_valid
    end

    it 'requires a new version to change published entitlements' do
      plan = create(:billing_plan)

      plan.entitlements = { 'limits' => { 'agents' => 10 } }

      expect(plan).not_to be_valid
      expect(plan.errors[:base]).to include('published plan versions cannot be changed')
    end
  end

  describe BillingPlanPrice do
    it 'requires a new plan version to change commercial terms' do
      price = create(:billing_plan_price)

      price.amount_cents += 1

      expect(price).not_to be_valid
      expect(price.errors[:base]).to include('price terms cannot be changed; create a new plan version')
    end

    it 'enforces non-negative money at the database boundary' do
      price = create(:billing_plan_price)

      # rubocop:disable Rails/SkipsModelValidations
      expect { price.update_column(:amount_cents, -1) }.to raise_error(ActiveRecord::StatementInvalid)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  describe BillingSubscription do
    it 'captures immutable catalog snapshots when created' do
      plan = create(:billing_plan, code: 'growth', name: 'Growth')
      price = create(:billing_plan_price, billing_plan: plan, amount_cents: 50_000_00)

      subscription = create(:billing_subscription, billing_plan: plan, billing_plan_price: price)

      expect(subscription.plan_snapshot).to include('name' => 'Growth', 'version' => 1)
      expect(subscription.price_snapshot).to include('amount_cents' => 50_000_00, 'currency' => 'KZT')
    end

    it 'rejects direct snapshot and catalog changes after creation' do
      subscription = create(:billing_subscription)
      original_plan_snapshot = subscription.plan_snapshot.deep_dup

      subscription.plan_snapshot = { 'code' => 'rewritten-history' }

      expect(subscription).not_to be_valid
      expect(subscription.errors[:base]).to include('subscription catalog snapshots cannot be changed')
      expect(subscription.reload.plan_snapshot).to eq(original_plan_snapshot)
    end

    it 'rejects subscriptions to unpublished plans' do
      plan = create(:billing_plan, status: 'draft')

      subscription = build(:billing_subscription, billing_plan: plan, billing_plan_price: nil)

      expect(subscription).not_to be_valid
      expect(subscription.errors[:billing_plan]).to include('must be active')
    end

    it 'enforces lifecycle states at the database boundary' do
      subscription = create(:billing_subscription)

      # rubocop:disable Rails/SkipsModelValidations
      expect { subscription.update_column(:status, 'unknown') }.to raise_error(ActiveRecord::StatementInvalid)
      # rubocop:enable Rails/SkipsModelValidations
    end

    it 'allows only one entitlement-bearing subscription per billing account' do
      billing_account = create(:billing_account)
      create(:billing_subscription, billing_account: billing_account, status: 'active')

      second_subscription = build(:billing_subscription, billing_account: billing_account, status: 'trialing')

      expect(second_subscription).not_to be_valid
      expect(second_subscription.errors[:billing_account_id]).to be_present
    end

    it 'requires a selected price to belong to the selected plan' do
      plan = create(:billing_plan)
      foreign_price = create(:billing_plan_price)

      subscription = build(:billing_subscription, billing_plan: plan, billing_plan_price: foreign_price)

      expect(subscription).not_to be_valid
      expect(subscription.errors[:billing_plan_price]).to include('must belong to the selected plan')
    end
  end

  describe BillingEntitlementAllocation do
    it 'allocates non-negative workspace limits within the same billing account' do
      subscription = create(:billing_subscription)
      account = create(:account)
      create(
        :billing_account_workspace,
        billing_account: subscription.billing_account,
        account: account
      )
      allocation = build(:billing_entitlement_allocation, billing_subscription: subscription, account: account)

      expect(allocation).to be_valid
    end

    it 'rejects allocation to a workspace owned by another billing account' do
      subscription = create(:billing_subscription)
      foreign_link = create(:billing_account_workspace)

      allocation = build(
        :billing_entitlement_allocation,
        billing_subscription: subscription,
        account: foreign_link.account
      )

      expect(allocation).not_to be_valid
      expect(allocation.errors[:account]).to include('must be an active workspace of the billing account')
    end

    it 'rejects negative allocated limits' do
      subscription = create(:billing_subscription)
      account = create(:account)
      create(
        :billing_account_workspace,
        billing_account: subscription.billing_account,
        account: account
      )
      allocation = build(
        :billing_entitlement_allocation,
        billing_subscription: subscription,
        account: account,
        limits: { 'agents' => -1 }
      )

      expect(allocation).not_to be_valid
      expect(allocation.errors[:limits]).to include('must contain only non-negative numbers')
    end

    it 'does not block normal workspace deletion' do
      subscription = create(:billing_subscription)
      account = create(:account)
      create(:billing_account_workspace, billing_account: subscription.billing_account, account: account)
      create(:billing_entitlement_allocation, billing_subscription: subscription, account: account)

      expect { account.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
