require 'rails_helper'
require Rails.root.join('db/migrate/20260226153427_disable_report_rollup_for_all_accounts')

RSpec.describe DisableReportRollupForAllAccounts do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:reclaimed_flag) { 1 << 19 }

  after do
    connection.execute('DROP TABLE IF EXISTS pg_temp.accounts')
    connection.schema_cache.clear!
    Account.reset_column_information
  end

  def use_historical_accounts_table
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE accounts (
        id bigserial PRIMARY KEY,
        feature_flags bigint DEFAULT 0 NOT NULL,
        updated_at timestamp NOT NULL DEFAULT NOW()
      ) ON COMMIT DROP
    SQL
  end

  it 'migrates an empty historical schema without loading the current Account model, including on retry' do
    expect(Account).not_to receive(:find_each)
    use_historical_accounts_table

    2.times { migration.migrate(:up) }

    expect(connection.select_value('SELECT COUNT(*) FROM accounts').to_i).to eq(0)
  end

  it 'clears the reclaimed twentieth bit on the historical schema and preserves all other bits and unchanged timestamps' do
    use_historical_accounts_table
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) SELECT #{reclaimed_flag | 8}, '2024-01-01' FROM generate_series(1, 101)")
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) VALUES (16, '2024-01-01')")

    migration.migrate(:up)

    rows = connection.select_all('SELECT feature_flags, updated_at FROM accounts ORDER BY id').to_a
    expect(rows.first(101).map { |row| row['feature_flags'].to_i }.uniq).to eq([8])
    expect(rows.last['feature_flags'].to_i).to eq(16)
    expect(rows.first['updated_at'].to_s).not_to start_with('2024-01-01')
    expect(rows.last['updated_at'].to_s).to start_with('2024-01-01')

    migration.migrate(:up)
    expect(connection.select_all('SELECT feature_flags, updated_at FROM accounts ORDER BY id').to_a).to eq(rows)
  end

  it 'removes only the overflow feature on an installed schema without changing the legacy twentieth bit' do
    account_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, feature_flags_overflow, created_at, updated_at)
      VALUES ('Installed', #{reclaimed_flag | 8}, '["report_rollup", "other"]', NOW(), '2024-01-01') RETURNING id
    SQL
    unaffected_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, feature_flags_overflow, created_at, updated_at)
      VALUES ('Unaffected', 16, '["other"]', NOW(), '2024-01-01') RETURNING id
    SQL

    migration.migrate(:up)
    after_first = connection.select_all('SELECT id, feature_flags, feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a
    migration.migrate(:up)
    expect(connection.select_all('SELECT id, feature_flags, feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a).to eq(after_first)

    row = connection.select_one("SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts WHERE id = #{account_id}")
    expect(row['feature_flags'].to_i).to eq(reclaimed_flag | 8)
    expect(JSON.parse(row['feature_flags_overflow'])).to eq(['other'])
    expect(row['updated_at'].to_s).not_to start_with('2024-01-01')
    unaffected = connection.select_one("SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts WHERE id = #{unaffected_id}")
    expect(unaffected['feature_flags'].to_i).to eq(16)
    expect(JSON.parse(unaffected['feature_flags_overflow'])).to eq(['other'])
    expect(unaffected['updated_at'].to_s).to start_with('2024-01-01')
  end
end
