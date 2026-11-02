require 'rails_helper'
require Rails.root.join('db/migrate/20261102093000_manage_organization_billing_foundation')

RSpec.describe ManageOrganizationBillingFoundation do
  # DDL is transactional. Do not run the global committed-row truncator with a private search_path.
  self.use_transactional_tests = true

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    schema = "foundation_spec_#{SecureRandom.hex(5)}"
    previous = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = "#{schema},public"
    connection.create_table(:accounts, id: :integer) { |table| table.string :name }
    connection.create_table(:organizations) { |table| table.string :name }
    ActiveRecord::Migration.suppress_messages { example.run }
  ensure
    connection.schema_search_path = previous
    connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    connection.schema_cache.clear!
  end

  def load_legacy
    load Rails.root.join('spec/fixtures/billing/legacy_foundation_schema.rb')
    connection.execute("INSERT INTO accounts (id,name) VALUES (1,'Synthetic workspace')")
    connection.execute("INSERT INTO billing_accounts (id,name,created_at,updated_at) VALUES (1,'Synthetic legacy payer',NOW(),NOW())")
    connection.execute('INSERT INTO billing_plans (id) VALUES (1)')
    connection.execute('INSERT INTO billing_account_workspaces (id,account_id,billing_account_id,created_at,updated_at) VALUES (1,1,1,NOW(),NOW())')
    connection.execute(<<~SQL.squish)
      INSERT INTO billing_subscriptions (id,billing_account_id,billing_plan_id,status,created_at,updated_at)
      VALUES (1,1,1,'canceled',NOW(),NOW())
    SQL
  end

  def legacy_rows
    described_class::TABLES.index_with { |table| connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a }
  end

  {
    [:billing_accounts, :default_currency] => 'USD',
    [:billing_accounts, :default_locale] => 'en',
    [:billing_subscriptions, :cancel_at_period_end] => true,
    [:billing_subscriptions, :plan_snapshot] => { 'tampered' => true },
    [:billing_subscriptions, :price_snapshot] => { 'tampered' => true }
  }.each do |(table, column), value|
    it "rejects drifted #{table}.#{column} default before DDL and preserves every legacy row" do
      load_legacy
      before = legacy_rows
      connection.change_column_default(table, column, value)

      expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible default #{table}.#{column}/)
      expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
      expect(legacy_rows).to eq(before)
    end
  end

  it 'rejects an unexpected expression even when its extracted literal default is nil' do
    load_legacy
    before = legacy_rows
    connection.execute('ALTER TABLE billing_accounts ALTER COLUMN name SET DEFAULT CURRENT_USER')

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible default billing_accounts.name/)
    expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
    expect(legacy_rows).to eq(before)
  end

  it 'rejects a missing real primary key before DDL and keeps occupied rows intact' do
    load_legacy
    before = legacy_rows
    connection.execute('ALTER TABLE billing_account_workspaces DROP CONSTRAINT billing_account_workspaces_pkey')

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible primary key billing_account_workspaces/)
    expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
    expect(legacy_rows).to eq(before)
  end

  it 'rejects an id with a valid primary key but without its generation default' do
    load_legacy
    connection.execute('ALTER TABLE billing_account_workspaces ALTER COLUMN id DROP DEFAULT')

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible id generation billing_account_workspaces.id/)
    expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
  end

  it 'rejects a real unique index marked invalid in PostgreSQL' do
    load_legacy
    index = "#{connection.quote_table_name(connection.current_schema)}.idx_billing_subscriptions_one_entitling"
    connection.execute("UPDATE pg_index SET indisvalid = false WHERE indexrelid = #{connection.quote(index)}::regclass")

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible unique index/)
    expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
  end

  it 'creates only the necessary foundation on a fresh schema, with interval GiST support' do
    migration.up
    local = connection.select_values('SELECT tablename FROM pg_tables WHERE schemaname = current_schema()')
    expect(local).to match_array(%w[accounts organizations billing_accounts billing_subscriptions billing_account_workspaces])
    expect(connection.extension_enabled?('btree_gist')).to be(true)
    expect(connection.exclusion_constraints(:billing_account_workspaces).map(&:name)).to include('excl_billing_workspace_intervals')
    expect(connection.columns(:billing_subscriptions).find { |column| column.name == 'billing_plan_id' }.null).to be(true)
    expect(connection.columns(:billing_accounts).find { |column| column.name == 'foundation_state' }.default).to eq('ready')
    expect(connection.foreign_keys(:billing_account_workspaces).find { |key| key.column == 'account_id' }.on_delete).to be_nil
  end

  it 'preserves occupied legacy data without guessing ownership, timestamps, status or snapshots' do
    load_legacy
    before = connection.select_one('SELECT * FROM billing_subscriptions WHERE id=1')
    migration.up

    expect(connection.select_one('SELECT * FROM billing_subscriptions WHERE id=1').except('foundation_state')).to eq(before)
    expect(connection.select_value('SELECT foundation_state FROM billing_accounts WHERE id=1')).to eq('legacy_pending')
    expect(connection.select_value('SELECT organization_id FROM billing_accounts WHERE id=1')).to be_nil
    expect(connection.select_value('SELECT starts_at FROM billing_account_workspaces WHERE id=1')).to be_nil
    expect(connection.select_value('SELECT COUNT(*) FROM billing_plans')).to eq(1)
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Retain additive billing schema/)
    expect(connection.select_value('SELECT COUNT(*) FROM billing_account_workspaces')).to eq(1)
  end

  it 'refuses incompatible columns before any foundation alteration' do
    load_legacy
    connection.change_column(:billing_account_workspaces, :metadata, :json, default: {})

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible billing_account_workspaces.metadata/)
    expect(connection.column_exists?(:billing_accounts, :foundation_state)).to be(false)
  end

  it 'refuses a weakened unique index and a weakened check instead of silently accepting them' do
    load_legacy
    connection.remove_index(:billing_subscriptions, name: 'idx_billing_subscriptions_one_entitling')
    connection.add_index(:billing_subscriptions, :billing_account_id, name: 'idx_billing_subscriptions_one_entitling')
    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible unique index/)
    connection.remove_check_constraint(:billing_accounts, name: 'chk_billing_accounts_status')
    connection.add_check_constraint(:billing_accounts, 'true', name: 'chk_billing_accounts_status')
    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /incompatible constraint/)
    expect(connection.column_exists?(:billing_accounts, :organization_id)).to be(false)
  end

  it 'refuses partial tables and missing foreign keys before altering legacy rows' do
    load_legacy
    connection.remove_foreign_key(:billing_subscriptions, :billing_plans)
    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /missing validated FK/)
    connection.drop_table(:billing_subscriptions)
    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /partial billing foundation/)
    expect(connection.column_exists?(:billing_accounts, :organization_id)).to be(false)
  end
end
