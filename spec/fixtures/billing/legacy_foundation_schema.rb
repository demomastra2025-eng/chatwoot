# Synthetic legacy structure copied from the three tracked abadea table definitions.
# rubocop:disable Layout/LineLength -- Preserve the historical constraint SQL verbatim.
ActiveRecord::Schema[7.2].define do
  create_table(:billing_plans) { |t| t.string :code }
  create_table(:billing_plan_prices) { |t| t.bigint :billing_plan_id }
  create_table 'billing_accounts' do |t|
    t.string 'name', null: false
    t.string 'status', default: 'active', null: false
    t.string 'default_currency', limit: 3, default: 'KZT', null: false
    t.string 'default_locale', default: 'ru', null: false
    t.jsonb 'metadata', default: {}, null: false
    t.datetime 'created_at', null: false
    t.datetime 'updated_at', null: false
    t.index ['status'], name: 'index_billing_accounts_on_status'
    t.check_constraint "default_currency::text ~ '^[A-Z]{3}$'::text", name: 'chk_billing_accounts_currency'
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'past_due'::character varying::text, 'suspended'::character varying::text, 'closed'::character varying::text])",
                       name: 'chk_billing_accounts_status'
  end
  create_table 'billing_account_workspaces' do |t|
    t.bigint 'billing_account_id', null: false
    t.integer 'account_id', null: false
    t.string 'status', default: 'active', null: false
    t.datetime 'detached_at'
    t.jsonb 'metadata', default: {}, null: false
    t.datetime 'created_at', null: false
    t.datetime 'updated_at', null: false
    t.index ['account_id'], name: 'idx_billing_workspaces_one_active_account', unique: true, where: "((status)::text = 'active'::text)"
    t.index ['account_id'], name: 'index_billing_account_workspaces_on_account_id'
    t.index ['billing_account_id'], name: 'index_billing_account_workspaces_on_billing_account_id'
    t.check_constraint "status::text = 'active'::text AND detached_at IS NULL OR status::text = 'detached'::text AND detached_at IS NOT NULL",
                       name: 'chk_billing_workspaces_detached_at'
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'detached'::character varying::text])",
                       name: 'chk_billing_workspaces_status'
  end
  create_table 'billing_subscriptions' do |t|
    t.bigint 'billing_account_id', null: false
    t.bigint 'billing_plan_id', null: false
    t.bigint 'billing_plan_price_id'
    t.string 'status', default: 'incomplete', null: false
    t.datetime 'current_period_starts_at'
    t.datetime 'current_period_ends_at'
    t.boolean 'cancel_at_period_end', default: false, null: false
    t.string 'provider'
    t.string 'external_id'
    t.jsonb 'plan_snapshot', default: {}, null: false
    t.jsonb 'price_snapshot', default: {}, null: false
    t.jsonb 'metadata', default: {}, null: false
    t.datetime 'created_at', null: false
    t.datetime 'updated_at', null: false
    t.index ['billing_account_id'], name: 'idx_billing_subscriptions_one_entitling', unique: true,
                                    where: "((status)::text = ANY (ARRAY[('trialing'::character varying)::text, ('active'::character varying)::text, ('past_due'::character varying)::text, ('grace_period'::character varying)::text]))"
    t.index ['billing_account_id'], name: 'index_billing_subscriptions_on_billing_account_id'
    t.index ['billing_plan_id'], name: 'index_billing_subscriptions_on_billing_plan_id'
    t.index ['billing_plan_price_id'], name: 'index_billing_subscriptions_on_billing_plan_price_id'
    t.index %w[provider external_id], name: 'idx_billing_subscriptions_provider_external', unique: true, where: '(external_id IS NOT NULL)'
    t.check_constraint 'current_period_starts_at IS NULL OR current_period_ends_at IS NULL OR current_period_ends_at > current_period_starts_at',
                       name: 'chk_billing_subscriptions_period'
    t.check_constraint "status::text = ANY (ARRAY['incomplete'::character varying::text, 'trialing'::character varying::text, 'active'::character varying::text, 'past_due'::character varying::text, 'grace_period'::character varying::text, 'suspended'::character varying::text, 'canceled'::character varying::text])",
                       name: 'chk_billing_subscriptions_status'
  end
  add_foreign_key :billing_account_workspaces, :accounts, on_delete: :cascade
  add_foreign_key :billing_account_workspaces, :billing_accounts
  add_foreign_key :billing_subscriptions, :billing_accounts
  add_foreign_key :billing_subscriptions, :billing_plans
  add_foreign_key :billing_subscriptions, :billing_plan_prices
end
# rubocop:enable Layout/LineLength
