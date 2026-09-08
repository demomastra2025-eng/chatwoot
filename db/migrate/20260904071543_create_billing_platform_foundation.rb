class CreateBillingPlatformFoundation < ActiveRecord::Migration[7.1]
  ACTIVE_SUBSCRIPTION_STATUSES = %w[trialing active past_due grace_period].freeze

  def change
    create_billing_accounts
    create_billing_account_memberships
    create_billing_account_workspaces
    create_billing_plans
    create_billing_plan_prices
    create_billing_subscriptions
    create_billing_entitlement_allocations
  end

  private

  def create_billing_accounts
    create_table :billing_accounts do |t|
      t.string :name, null: false
      t.string :status, null: false, default: 'active'
      t.string :default_currency, null: false, default: 'KZT', limit: 3
      t.string :default_locale, null: false, default: 'ru'
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :billing_accounts, :status
  end

  def create_billing_account_memberships
    create_table :billing_account_memberships do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.string :status, null: false, default: 'active'
      t.timestamps
    end

    add_billing_membership_indexes
  end

  def add_billing_membership_indexes
    add_index :billing_account_memberships,
              [:billing_account_id, :user_id],
              unique: true,
              name: 'idx_billing_memberships_account_user'
    add_index :billing_account_memberships,
              :billing_account_id,
              unique: true,
              where: "role = 'owner' AND status = 'active'",
              name: 'idx_billing_memberships_one_active_owner'
  end

  def create_billing_account_workspaces
    create_table :billing_account_workspaces do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.references :account, type: :integer, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: 'active'
      t.datetime :detached_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :billing_account_workspaces,
              :account_id,
              unique: true,
              where: "status = 'active'",
              name: 'idx_billing_workspaces_one_active_account'
  end

  def create_billing_plans
    create_table :billing_plans do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.integer :version, null: false, default: 1
      t.string :status, null: false, default: 'draft'
      t.boolean :public, null: false, default: false
      t.jsonb :entitlements, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :billing_plans, [:code, :version], unique: true
    add_index :billing_plans, [:status, :public]
  end

  def create_billing_plan_prices
    create_table :billing_plan_prices do |t|
      t.references :billing_plan, null: false, foreign_key: true
      t.string :currency, null: false, limit: 3
      t.bigint :amount_cents, null: false
      t.string :interval, null: false
      t.integer :interval_count, null: false, default: 1
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :billing_plan_prices,
              [:billing_plan_id, :currency, :interval, :interval_count],
              unique: true,
              name: 'idx_billing_prices_unique_period'
  end

  def create_billing_subscriptions
    create_table :billing_subscriptions do |t|
      add_billing_subscription_columns(t)
      t.timestamps
    end

    add_billing_subscription_indexes
  end

  def add_billing_subscription_columns(table)
    table.references :billing_account, null: false, foreign_key: true
    table.references :billing_plan, null: false, foreign_key: true
    table.references :billing_plan_price, foreign_key: true
    table.string :status, null: false, default: 'incomplete'
    table.datetime :current_period_starts_at
    table.datetime :current_period_ends_at
    table.boolean :cancel_at_period_end, null: false, default: false
    table.string :provider
    table.string :external_id
    table.jsonb :plan_snapshot, null: false, default: {}
    table.jsonb :price_snapshot, null: false, default: {}
    table.jsonb :metadata, null: false, default: {}
  end

  def add_billing_subscription_indexes
    quoted_statuses = ACTIVE_SUBSCRIPTION_STATUSES.map { |status| connection.quote(status) }.join(', ')
    add_index :billing_subscriptions,
              :billing_account_id,
              unique: true,
              where: "status IN (#{quoted_statuses})",
              name: 'idx_billing_subscriptions_one_entitling'
    add_index :billing_subscriptions,
              [:provider, :external_id],
              unique: true,
              where: 'external_id IS NOT NULL',
              name: 'idx_billing_subscriptions_provider_external'
  end

  def create_billing_entitlement_allocations
    create_table :billing_entitlement_allocations do |t|
      t.references :billing_subscription,
                   null: false,
                   foreign_key: true,
                   index: { name: 'idx_billing_allocations_subscription' }
      t.references :account, type: :integer, null: false, foreign_key: { on_delete: :cascade }
      t.jsonb :limits, null: false, default: {}
      t.datetime :starts_at
      t.datetime :ends_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :billing_entitlement_allocations,
              [:billing_subscription_id, :account_id],
              unique: true,
              name: 'idx_billing_allocations_subscription_account'
  end
end
