require 'rails_helper'
require Rails.root.join('db/migrate/20261102103000_create_billing_unit_ledger')

RSpec.describe CreateBillingUnitLedger do
  around do |example|
    connection = ActiveRecord::Base.connection
    schema = "unit_ledger_spec_#{SecureRandom.hex(5)}"
    previous = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = "#{schema},public"
    %i[accounts billing_accounts billing_subscriptions].each { |table| connection.create_table(table) }
    ActiveRecord::Migration.suppress_messages { example.run }
  ensure
    connection.schema_search_path = previous
    connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    connection.schema_cache.clear!
  end

  it 'creates only financial unit tables, preserves them on rollback, and has no Contact cascade' do
    migration = described_class.new
    migration.up
    connection = ActiveRecord::Base.connection
    local = connection.select_values('SELECT tablename FROM pg_tables WHERE schemaname=current_schema()')
    expect(local).to match_array(%w[accounts billing_accounts billing_subscriptions billing_usage_periods billing_usage_projections
                                    billing_usage_revisions])
    expect(connection.foreign_keys(:billing_usage_projections).map(&:to_table)).not_to include('contacts')
    expect(connection.foreign_keys(:billing_usage_projections).find { |key| key.to_table == 'accounts' }.on_delete).to be_nil
    expect(connection.indexes(:billing_usage_revisions).select(&:unique).map(&:name)).to include('idx_billing_usage_revision_order',
                                                                                                 'idx_billing_usage_revision_operation')
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it 'refuses existing ledger structure rather than silently adopting it' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:billing_usage_periods)
    expect { described_class.new.up }.to raise_error(ActiveRecord::MigrationError, /already exist/)
    count = connection.select_value("SELECT COUNT(*) FROM pg_tables WHERE schemaname=current_schema() AND tablename='billing_usage_projections'")
    expect(count).to eq(0)
  end
end
