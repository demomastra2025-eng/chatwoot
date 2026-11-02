# frozen_string_literal: true

# Deliberately additive. Legacy rows are quarantined, never assigned an invented owner/date/tariff.
# Historical DDL and compatibility checks stay self-contained rather than loading changing application code.
# rubocop:disable Metrics/ClassLength
class ManageOrganizationBillingFoundation < ActiveRecord::Migration[7.1]
  TABLES = %i[billing_accounts billing_account_workspaces billing_subscriptions].freeze
  ENTITLING = "status IN ('trialing', 'active', 'past_due', 'grace_period')"
  ACCOUNT_STATUS = "status::text = ANY (ARRAY['active'::text,'past_due'::text,'suspended'::text,'closed'::text])"
  SUBSCRIPTION_STATUS = "status::text = ANY (ARRAY['incomplete'::text,'trialing'::text,'active'::text,'past_due'::text," \
                        "'grace_period'::text,'suspended'::text,'canceled'::text])"
  WORKSPACE_STATUS = "status::text = ANY (ARRAY['active'::text,'detached'::text])"
  DETACHED = "status::text = 'active'::text AND detached_at IS NULL OR status::text = 'detached'::text AND detached_at IS NOT NULL"
  PERIOD = 'current_period_starts_at IS NULL OR current_period_ends_at IS NULL OR current_period_ends_at > current_period_starts_at'

  def up
    present = TABLES.select { |table| local_table?(table) }
    raise ActiveRecord::MigrationError, 'partial billing foundation: explicit structural repair required' if present.any? && present != TABLES

    present.empty? ? create_foundation : validate_legacy_foundation!
    add_ownership
    add_history
    add_subscription_contract
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Retain additive billing schema and financial history; rollback application source only. No automatic data adoption occurred.'
  end

  private

  def local_table?(table)
    connection.select_value("SELECT to_regclass(quote_ident(current_schema()) || '.' || #{connection.quote(table.to_s)})").present?
  end

  def create_foundation
    create_table(:billing_accounts) do |t|
      t.string :name, null: false
      t.string :status, null: false, default: 'active'
      t.string :default_currency, limit: 3, null: false, default: 'KZT'
      t.string :default_locale, null: false, default: 'ru'
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :billing_accounts, :status
    add_check_constraint :billing_accounts, ACCOUNT_STATUS, name: 'chk_billing_accounts_status'
    add_check_constraint :billing_accounts, "default_currency::text ~ '^[A-Z]{3}$'::text", name: 'chk_billing_accounts_currency'
    create_workspaces
    create_subscriptions
  end

  def create_workspaces
    create_table(:billing_account_workspaces) do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.integer :account_id, null: false
      t.string :status, null: false, default: 'active'
      t.datetime :detached_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :billing_account_workspaces, :accounts
    add_index :billing_account_workspaces, :account_id
    add_index :billing_account_workspaces, :account_id, unique: true, where: "status = 'active'", name: 'idx_billing_workspaces_one_active_account'
    add_check_constraint :billing_account_workspaces, WORKSPACE_STATUS, name: 'chk_billing_workspaces_status'
    add_check_constraint :billing_account_workspaces, DETACHED, name: 'chk_billing_workspaces_detached_at'
  end

  def create_subscriptions
    create_table(:billing_subscriptions) do |t|
      t.references :billing_account, null: false, foreign_key: true
      subscription_contract_fields(t)
      t.string :status, null: false, default: 'incomplete'
      t.datetime :current_period_starts_at
      t.datetime :current_period_ends_at
      t.boolean :cancel_at_period_end, null: false, default: false
      t.string :provider
      t.string :external_id
      t.timestamps
    end
    add_index :billing_subscriptions, :billing_plan_id
    add_index :billing_subscriptions, :billing_plan_price_id
    add_index :billing_subscriptions, :billing_account_id, unique: true, where: ENTITLING, name: 'idx_billing_subscriptions_one_entitling'
    add_index :billing_subscriptions, %i[provider external_id], unique: true,
                                                                where: 'external_id IS NOT NULL', name: 'idx_billing_subscriptions_provider_external'
    add_check_constraint :billing_subscriptions, SUBSCRIPTION_STATUS, name: 'chk_billing_subscriptions_status'
    add_check_constraint :billing_subscriptions, PERIOD, name: 'chk_billing_subscriptions_period'
  end

  def subscription_contract_fields(table)
    table.bigint :billing_plan_id
    table.bigint :billing_plan_price_id
    table.jsonb :plan_snapshot, null: false, default: {}
    table.jsonb :price_snapshot, null: false, default: {}
    table.jsonb :metadata, null: false, default: {}
  end

  def validate_legacy_foundation!
    TABLES.each { |table| validate_columns!(table) }
    validate_checks!(:billing_accounts, 'chk_billing_accounts_status' => ACCOUNT_STATUS,
                                        'chk_billing_accounts_currency' => "default_currency::text ~ '^[A-Z]{3}$'::text")
    validate_checks!(:billing_account_workspaces, 'chk_billing_workspaces_status' => WORKSPACE_STATUS,
                                                  'chk_billing_workspaces_detached_at' => DETACHED)
    validate_checks!(:billing_subscriptions, 'chk_billing_subscriptions_status' => SUBSCRIPTION_STATUS,
                                             'chk_billing_subscriptions_period' => PERIOD)
    validate_indexes_and_keys!
  end

  def validate_columns!(table)
    required = required_columns.fetch(table).merge('id' => ['bigint', false], 'created_at' => ['timestamp(6) without time zone', false],
                                                   'updated_at' => ['timestamp(6) without time zone', false])
    columns = connection.columns(table).index_by(&:name)
    required.each do |name, (type, nullable)|
      column = columns[name]
      next if column && column.sql_type == type && column.null == nullable

      raise ActiveRecord::MigrationError, "incompatible #{table}.#{name}: expected #{type}, nullable=#{nullable}"
    end
    defaults = { 'status' => { billing_accounts: 'active', billing_account_workspaces: 'active', billing_subscriptions: 'incomplete' }.fetch(table),
                 'metadata' => '{}' }
    defaults.each do |name, value|
      raise ActiveRecord::MigrationError, "incompatible default #{table}.#{name}" unless columns.fetch(name).default == value
    end
  end

  def required_columns
    common = { 'status' => ['character varying', false], 'metadata' => ['jsonb', false] }
    {
      billing_accounts: common.merge('name' => ['character varying', false], 'default_currency' => ['character varying(3)', false],
                                     'default_locale' => ['character varying', false]),
      billing_account_workspaces: common.merge('billing_account_id' => ['bigint', false], 'account_id' => ['integer', false],
                                               'detached_at' => ['timestamp(6) without time zone', true]),
      billing_subscriptions: common.merge('billing_account_id' => ['bigint', false], 'billing_plan_id' => ['bigint', false],
                                          'billing_plan_price_id' => ['bigint', true], 'plan_snapshot' => ['jsonb', false],
                                          'price_snapshot' => ['jsonb', false], 'cancel_at_period_end' => ['boolean', false],
                                          'provider' => ['character varying', true], 'external_id' => ['character varying', true],
                                          'current_period_starts_at' => ['timestamp(6) without time zone', true],
                                          'current_period_ends_at' => ['timestamp(6) without time zone', true])
    }
  end

  def normalized_sql(value)
    value.to_s.gsub(/::(?:character varying|text)(?:\[\])?/, '').gsub(/[\s()]/, '')
  end

  def validate_checks!(table, expected)
    actual = connection.check_constraints(table).index_by(&:name)
    expected.each do |name, expression|
      constraint = actual[name]
      next if constraint&.validated? && normalized_sql(constraint.expression) == normalized_sql(expression)

      raise ActiveRecord::MigrationError, "incompatible constraint #{table}.#{name}"
    end
  end

  def validate_index!(table, name, columns, predicate)
    index = connection.indexes(table).find { |value| value.name == name }
    return if index&.unique && index.columns == columns && normalized_sql(index.where) == normalized_sql(predicate)

    raise ActiveRecord::MigrationError, "incompatible unique index #{table}.#{name}"
  end

  def validate_indexes_and_keys!
    validate_index!(:billing_account_workspaces, 'idx_billing_workspaces_one_active_account', ['account_id'], "status = 'active'")
    validate_index!(:billing_subscriptions, 'idx_billing_subscriptions_one_entitling', ['billing_account_id'],
                    "status::text = ANY (ARRAY['trialing'::text,'active'::text,'past_due'::text,'grace_period'::text])")
    validate_index!(:billing_subscriptions, 'idx_billing_subscriptions_provider_external', %w[provider external_id], 'external_id IS NOT NULL')
    { billing_account_workspaces: { billing_accounts: 'billing_account_id', accounts: 'account_id' },
      billing_subscriptions: { billing_accounts: 'billing_account_id', billing_plans: 'billing_plan_id',
                               billing_plan_prices: 'billing_plan_price_id' } }.each do |table, keys|
      keys.each do |target, column|
        validate_foreign_key!(table, target, column)
      end
    end
  end

  def validate_foreign_key!(table, target, column)
    key = connection.foreign_keys(table).find { |fk| [fk.to_table, fk.column] == [target.to_s, column] }
    allowed_delete = [table, target] == [:billing_account_workspaces, :accounts] ? [nil, :cascade] : [nil]
    return if key&.validated? && key.primary_key == 'id' && allowed_delete.include?(key.on_delete)

    raise ActiveRecord::MigrationError, "missing validated FK #{table}.#{column} or incompatible deletion rule"
  end

  def add_state(table)
    add_column table, :foundation_state, :string, null: false, default: 'legacy_pending'
    change_column_default table, :foundation_state, from: 'legacy_pending', to: 'ready'
    add_check_constraint table, "foundation_state IN ('ready', 'legacy_pending')", name: "chk_#{table}_foundation_state"
  end

  def add_ownership
    add_state(:billing_accounts)
    add_reference :billing_accounts, :organization, foreign_key: true
    add_reference :billing_accounts, :standalone_account, foreign_key: { to_table: :accounts }
    owner_check = "foundation_state = 'legacy_pending' OR " \
                  "((organization_id IS NULL) <> (standalone_account_id IS NULL) AND default_currency = 'KZT')"
    add_check_constraint :billing_accounts, owner_check, name: 'chk_billing_accounts_explicit_owner'
    add_index :billing_accounts, :organization_id, unique: true, where: "foundation_state = 'ready'", name: 'idx_billing_accounts_org_owner'
    add_index :billing_accounts, :standalone_account_id, unique: true, where: "foundation_state = 'ready'",
                                                         name: 'idx_billing_accounts_standalone_owner'
  end

  def add_history
    add_state(:billing_account_workspaces)
    add_column :billing_account_workspaces, :starts_at, :datetime
    add_check_constraint :billing_account_workspaces,
                         "foundation_state = 'legacy_pending' OR (starts_at IS NOT NULL AND (detached_at IS NULL OR detached_at > starts_at))",
                         name: 'chk_billing_workspaces_known_interval'
    key = connection.foreign_keys(:billing_account_workspaces).find { |fk| fk.to_table == 'accounts' && fk.column == 'account_id' }
    remove_foreign_key :billing_account_workspaces, name: key.name
    add_foreign_key :billing_account_workspaces, :accounts
    enable_extension 'btree_gist' unless extension_enabled?('btree_gist')
    add_exclusion_constraint :billing_account_workspaces,
                             "account_id WITH =, tsrange(starts_at, detached_at, '[)') WITH &&",
                             using: :gist, where: "foundation_state = 'ready'", name: 'excl_billing_workspace_intervals'
  end

  def add_subscription_contract
    add_state(:billing_subscriptions)
    change_column_null :billing_subscriptions, :billing_plan_id, true
    add_check_constraint :billing_subscriptions, <<~SQL.squish, name: 'chk_billing_subscriptions_snapshot_contract'
      foundation_state = 'legacy_pending' OR (
        billing_plan_id IS NULL AND billing_plan_price_id IS NULL
        AND jsonb_typeof(plan_snapshot) = 'object' AND jsonb_typeof(price_snapshot) = 'object'
        AND plan_snapshot @> '{"schema_version":1,"source":"account_plans"}'::jsonb
        AND price_snapshot @> '{"schema_version":1,"source":"account_plans","currency":"KZT"}'::jsonb
        AND plan_snapshot ?& ARRAY['catalog_version','tariff','modules','features','limits','limit_sources']
        AND price_snapshot ?& ARRAY['catalog_version','tariff','pricing']
        AND plan_snapshot->'catalog_version' = price_snapshot->'catalog_version'
        AND plan_snapshot->'tariff' = price_snapshot->'tariff'
        AND jsonb_typeof(plan_snapshot->'limits') = 'object'
        AND jsonb_typeof(plan_snapshot->'limit_sources') = 'object'
        AND jsonb_typeof(price_snapshot->'pricing') = 'object'
      )
    SQL
  end
end
# rubocop:enable Metrics/ClassLength
