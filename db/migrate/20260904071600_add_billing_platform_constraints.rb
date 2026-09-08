class AddBillingPlatformConstraints < ActiveRecord::Migration[7.1]
  def change
    add_billing_account_constraints
    add_billing_membership_constraints
    add_billing_workspace_constraints
    add_billing_plan_constraints
    add_billing_price_constraints
    add_billing_subscription_constraints
    add_billing_allocation_constraints
  end

  private

  def add_billing_account_constraints
    add_check_constraint :billing_accounts, "status IN ('active', 'past_due', 'suspended', 'closed')",
                         name: 'chk_billing_accounts_status'
    add_check_constraint :billing_accounts, "default_currency ~ '^[A-Z]{3}$'",
                         name: 'chk_billing_accounts_currency'
  end

  def add_billing_membership_constraints
    add_check_constraint :billing_account_memberships, "role IN ('owner', 'billing_admin', 'viewer')",
                         name: 'chk_billing_memberships_role'
    add_check_constraint :billing_account_memberships, "status IN ('active', 'inactive')",
                         name: 'chk_billing_memberships_status'
  end

  def add_billing_workspace_constraints
    add_check_constraint :billing_account_workspaces, "status IN ('active', 'detached')",
                         name: 'chk_billing_workspaces_status'
    add_check_constraint :billing_account_workspaces,
                         "(status = 'active' AND detached_at IS NULL) OR (status = 'detached' AND detached_at IS NOT NULL)",
                         name: 'chk_billing_workspaces_detached_at'
  end

  def add_billing_plan_constraints
    add_check_constraint :billing_plans, "status IN ('draft', 'active', 'retired')",
                         name: 'chk_billing_plans_status'
    add_check_constraint :billing_plans, 'version > 0', name: 'chk_billing_plans_version'
  end

  def add_billing_price_constraints
    add_check_constraint :billing_plan_prices, "currency ~ '^[A-Z]{3}$'", name: 'chk_billing_prices_currency'
    add_check_constraint :billing_plan_prices, 'amount_cents >= 0', name: 'chk_billing_prices_amount'
    add_check_constraint :billing_plan_prices, "interval IN ('month', 'year')", name: 'chk_billing_prices_interval'
    add_check_constraint :billing_plan_prices, 'interval_count > 0', name: 'chk_billing_prices_interval_count'
  end

  def add_billing_subscription_constraints
    statuses = "'incomplete', 'trialing', 'active', 'past_due', 'grace_period', 'suspended', 'canceled'"
    add_check_constraint :billing_subscriptions, "status IN (#{statuses})", name: 'chk_billing_subscriptions_status'
    add_check_constraint :billing_subscriptions,
                         'current_period_starts_at IS NULL OR current_period_ends_at IS NULL OR current_period_ends_at > current_period_starts_at',
                         name: 'chk_billing_subscriptions_period'
  end

  def add_billing_allocation_constraints
    add_check_constraint :billing_entitlement_allocations,
                         'starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at',
                         name: 'chk_billing_allocations_period'
  end
end
