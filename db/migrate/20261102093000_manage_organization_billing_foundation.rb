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
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    present = TABLES.select { |table| local_table?(table) }
    raise ActiveRecord::MigrationError, 'partial billing foundation: explicit structural repair required' if present.any? && present != TABLES

    if present.empty?
      create_foundation
    else
      lock_bounded_legacy_foundation!
      validate_legacy_foundation!
    end
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
    add_check_constraint :billing_accounts, ACCOUNT_STATUS, name: 'chk_billing_accounts_status', validate: false
    validate_check_constraint :billing_accounts, name: 'chk_billing_accounts_status'
    add_check_constraint :billing_accounts, "default_currency::text ~ '^[A-Z]{3}$'::text", name: 'chk_billing_accounts_currency', validate: false
    validate_check_constraint :billing_accounts, name: 'chk_billing_accounts_currency'
    create_workspaces
    create_subscriptions
    add_foreign_key :billing_account_workspaces, :billing_accounts, validate: false
    validate_foreign_key :billing_account_workspaces, :billing_accounts
    add_foreign_key :billing_subscriptions, :billing_accounts, validate: false
    validate_foreign_key :billing_subscriptions, :billing_accounts
  end

  def create_workspaces
    create_table(:billing_account_workspaces) do |t|
      t.references :billing_account, null: false
      t.integer :account_id, null: false
      t.string :status, null: false, default: 'active'
      t.datetime :detached_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :billing_account_workspaces, :accounts, validate: false
    validate_foreign_key :billing_account_workspaces, :accounts
    add_index :billing_account_workspaces, :account_id
    add_index :billing_account_workspaces, :account_id, unique: true, where: "status = 'active'", name: 'idx_billing_workspaces_one_active_account'
    add_check_constraint :billing_account_workspaces, WORKSPACE_STATUS, name: 'chk_billing_workspaces_status', validate: false
    validate_check_constraint :billing_account_workspaces, name: 'chk_billing_workspaces_status'
    add_check_constraint :billing_account_workspaces, DETACHED, name: 'chk_billing_workspaces_detached_at', validate: false
    validate_check_constraint :billing_account_workspaces, name: 'chk_billing_workspaces_detached_at'
  end

  # Explicit NOT VALID / VALIDATE pairs keep the final historical schema validated.
  # rubocop:disable Metrics/MethodLength
  def create_subscriptions
    create_table(:billing_subscriptions) do |t|
      t.references :billing_account, null: false
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
    add_check_constraint :billing_subscriptions, SUBSCRIPTION_STATUS, name: 'chk_billing_subscriptions_status', validate: false
    validate_check_constraint :billing_subscriptions, name: 'chk_billing_subscriptions_status'
    add_check_constraint :billing_subscriptions, PERIOD, name: 'chk_billing_subscriptions_period', validate: false
    validate_check_constraint :billing_subscriptions, name: 'chk_billing_subscriptions_period'
  end

  # rubocop:enable Metrics/MethodLength

  def subscription_contract_fields(table)
    table.bigint :billing_plan_id
    table.bigint :billing_plan_price_id
    table.jsonb :plan_snapshot, null: false, default: {}
    table.jsonb :price_snapshot, null: false, default: {}
    table.jsonb :metadata, null: false, default: {}
  end

  # Locks close the cap-check/DDL race. The 5s statement budget is per statement, not
  # a promise about total transaction duration. Larger legacy needs maintenance.
  def lock_bounded_legacy_foundation!
    validate_legacy_relations!
    execute 'LOCK TABLE billing_accounts, billing_account_workspaces, billing_subscriptions IN ACCESS EXCLUSIVE MODE'
    validate_legacy_relations!
    TABLES.each do |table|
      size = select_value("SELECT pg_total_relation_size(to_regclass(#{relation_literal(table)}))").to_i
      rows = select_value("SELECT count(*) FROM (SELECT 1 FROM ONLY #{connection.quote_table_name(table)} LIMIT 513) bounded_rows").to_i
      next if size <= 1_048_576 && rows <= 512

      raise ActiveRecord::MigrationError, "billing foundation exceeds tiny limits: explicit maintenance required (#{table})"
    end
  end

  def validate_legacy_relations!
    TABLES.each do |table|
      ordinary = select_value(<<~SQL.squish)
        SELECT relkind = 'r' AND relpersistence = 'p' AND NOT relispartition
          AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = relation.oid OR inhparent = relation.oid)
        FROM pg_class relation WHERE oid = to_regclass(#{relation_literal(table)})
      SQL
      raise ActiveRecord::MigrationError, "non-ordinary billing foundation: explicit maintenance required (#{table})" unless ordinary
    end
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
    raise ActiveRecord::MigrationError, "unexpected columns in #{table}" if (columns.keys - required.keys).any?

    required.each do |name, (type, nullable)|
      column = columns[name]
      next if column && column.sql_type == type && column.null == nullable

      raise ActiveRecord::MigrationError, "incompatible #{table}.#{name}: expected #{type}, nullable=#{nullable}"
    end
    validate_defaults!(table, columns)
    validate_primary_key!(table)
  end

  def validate_defaults!(table, columns)
    common = { 'metadata' => '{}' }
    expected = {
      billing_accounts: common.merge('status' => 'active', 'default_currency' => 'KZT', 'default_locale' => 'ru'),
      billing_account_workspaces: common.merge('status' => 'active'),
      billing_subscriptions: common.merge('status' => 'incomplete', 'cancel_at_period_end' => 'false',
                                          'plan_snapshot' => '{}', 'price_snapshot' => '{}')
    }.fetch(table)
    expressions = default_expressions(table)
    columns.except('id').each do |name, column|
      next if expressions[name] == literal_default_expression(column, expected[name])

      raise ActiveRecord::MigrationError, "incompatible default #{table}.#{name}"
    end
  end

  # Rails' Column parser reports both default/default_function=nil for keywords such as CURRENT_USER.
  # Compare PostgreSQL's actual expression, including the required absence of a default.
  def default_expressions(table)
    connection.select_rows(<<~SQL.squish).to_h
      SELECT attr.attname, pg_get_expr(def.adbin, def.adrelid)
      FROM pg_attribute attr LEFT JOIN pg_attrdef def ON def.adrelid = attr.attrelid AND def.adnum = attr.attnum
      WHERE attr.attrelid = to_regclass(#{relation_literal(table)}) AND attr.attnum > 0 AND NOT attr.attisdropped
    SQL
  end

  def literal_default_expression(column, value)
    return if value.nil?
    return value if column.type == :boolean

    type = column.type == :jsonb ? 'jsonb' : 'character varying'
    "#{connection.quote(value)}::#{type}"
  end

  def relation_literal(table)
    connection.quote("#{connection.quote_table_name(connection.current_schema)}.#{connection.quote_table_name(table)}")
  end

  def validate_primary_key!(table)
    valid = connection.select_value(<<~SQL.squish)
      SELECT idx.indisvalid AND idx.indisready AND idx.indislive AND idx.indisunique AND idx.indimmediate
        AND idx.indnkeyatts = 1 AND idx.indnatts = 1 AND attr.attname = 'id'
        AND con.convalidated AND NOT con.condeferrable
      FROM pg_index idx
      JOIN pg_constraint con ON con.conindid = idx.indexrelid AND con.contype = 'p'
      JOIN pg_attribute attr ON attr.attrelid = idx.indrelid AND attr.attnum = idx.indkey[0]
      WHERE idx.indrelid = to_regclass(#{relation_literal(table)}) AND idx.indisprimary
    SQL
    raise ActiveRecord::MigrationError, "incompatible primary key #{table}: expected valid id PK" unless valid

    validate_id_generator!(table)
  end

  def validate_id_generator!(table)
    generator = connection.select_one(<<~SQL.squish)
      SELECT attr.attidentity AS identity_kind, pg_get_expr(def.adbin, def.adrelid) AS expression,
        seq.seqincrement > 0 AND NOT seq.seqcycle AS sequence_ok,
        EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.classid = 'pg_attrdef'::regclass
          AND dep.objid = def.oid AND dep.refclassid = 'pg_class'::regclass AND dep.refobjid = seq.seqrelid) AS default_uses_owned_sequence
      FROM pg_attribute attr
      LEFT JOIN pg_attrdef def ON def.adrelid = attr.attrelid AND def.adnum = attr.attnum
      LEFT JOIN pg_sequence seq ON seq.seqrelid = pg_get_serial_sequence(#{relation_literal(table)}, 'id')::regclass
      WHERE attr.attrelid = to_regclass(#{relation_literal(table)}) AND attr.attname = 'id'
    SQL
    direct_serial = generator['expression'].to_s.match?(/\Anextval\('(?:[^']|'')+'::regclass\)\z/) && generator['default_uses_owned_sequence']
    valid = generator['sequence_ok'] && (%w[a d].include?(generator['identity_kind']) || direct_serial)
    raise ActiveRecord::MigrationError, "incompatible id generation #{table}.id" unless valid
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
    return if index&.unique && index.columns == columns && normalized_sql(index.where) == normalized_sql(predicate) && valid_unique_index?(table,
                                                                                                                                           name)

    raise ActiveRecord::MigrationError, "incompatible unique index #{table}.#{name}"
  end

  def valid_unique_index?(table, name)
    connection.select_value(<<~SQL.squish)
      SELECT indisvalid AND indisready AND indislive AND indisunique AND indimmediate
      FROM pg_index WHERE indrelid = to_regclass(#{relation_literal(table)}) AND indexrelid = to_regclass(#{relation_literal(name)})
    SQL
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
    add_check_constraint table, "foundation_state IN ('ready', 'legacy_pending')", name: "chk_#{table}_foundation_state", validate: false
    validate_check_constraint table, name: "chk_#{table}_foundation_state"
  end

  def add_ownership
    add_state(:billing_accounts)
    add_reference :billing_accounts, :organization
    add_reference :billing_accounts, :standalone_account
    add_foreign_key :billing_accounts, :organizations, validate: false
    validate_foreign_key :billing_accounts, :organizations
    add_foreign_key :billing_accounts, :accounts, column: :standalone_account_id, validate: false
    validate_foreign_key :billing_accounts, :accounts, column: :standalone_account_id
    owner_check = "foundation_state = 'legacy_pending' OR " \
                  "((organization_id IS NULL) <> (standalone_account_id IS NULL) AND default_currency = 'KZT')"
    add_check_constraint :billing_accounts, owner_check, name: 'chk_billing_accounts_explicit_owner', validate: false
    validate_check_constraint :billing_accounts, name: 'chk_billing_accounts_explicit_owner'
    add_index :billing_accounts, :organization_id, unique: true, where: "foundation_state = 'ready'", name: 'idx_billing_accounts_org_owner'
    add_index :billing_accounts, :standalone_account_id, unique: true, where: "foundation_state = 'ready'",
                                                         name: 'idx_billing_accounts_standalone_owner'
  end

  def add_history
    add_state(:billing_account_workspaces)
    add_column :billing_account_workspaces, :starts_at, :datetime
    add_check_constraint :billing_account_workspaces,
                         "foundation_state = 'legacy_pending' OR (starts_at IS NOT NULL AND (detached_at IS NULL OR detached_at > starts_at))",
                         name: 'chk_billing_workspaces_known_interval', validate: false
    validate_check_constraint :billing_account_workspaces, name: 'chk_billing_workspaces_known_interval'
    key = connection.foreign_keys(:billing_account_workspaces).find { |fk| fk.to_table == 'accounts' && fk.column == 'account_id' }
    remove_foreign_key :billing_account_workspaces, name: key.name
    add_foreign_key :billing_account_workspaces, :accounts, validate: false
    validate_foreign_key :billing_account_workspaces, :accounts
    enable_extension 'btree_gist' unless extension_enabled?('btree_gist')
    add_exclusion_constraint :billing_account_workspaces,
                             "account_id WITH =, tsrange(starts_at, detached_at, '[)') WITH &&",
                             using: :gist, where: "foundation_state = 'ready'", name: 'excl_billing_workspace_intervals'
  end

  def add_subscription_contract
    add_state(:billing_subscriptions)
    change_column_null :billing_subscriptions, :billing_plan_id, true
    add_check_constraint :billing_subscriptions, <<~SQL.squish, name: 'chk_billing_subscriptions_snapshot_contract', validate: false
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
    validate_check_constraint :billing_subscriptions, name: 'chk_billing_subscriptions_snapshot_contract'
  end
end
# rubocop:enable Metrics/ClassLength
