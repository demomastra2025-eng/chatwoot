require 'rails_helper'
require Rails.root.join('db/migrate/20260120121402_enable_captain_tasks_for_existing_accounts')

RSpec.describe EnableCaptainTasksForExistingAccounts do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:captain_tasks_flag) { 1 << 60 }

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
    expect(Account).not_to receive(:find_in_batches)
    use_historical_accounts_table

    2.times { migration.migrate(:up) }

    expect(connection.select_value('SELECT COUNT(*) FROM accounts').to_i).to eq(0)
  end

  it 'enables the original bit for every installed account and preserves other flags and timestamps on retry' do
    use_historical_accounts_table
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) SELECT 8, '2024-01-01' FROM generate_series(1, 101)")
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) VALUES (#{captain_tasks_flag | 16}, '2024-01-01')")

    migration.migrate(:up)
    expect(connection.select_value("SELECT COUNT(*) FROM accounts WHERE feature_flags = #{captain_tasks_flag | 8}").to_i).to eq(101)
    expect(connection.select_value("SELECT COUNT(*) FROM accounts WHERE feature_flags = #{captain_tasks_flag | 16}").to_i).to eq(1)
    before_retry = connection.select_all('SELECT feature_flags, updated_at FROM accounts ORDER BY id').to_a
    expect(before_retry.last['updated_at'].to_s).to start_with('2024-01-01')
    expect(before_retry.first['updated_at'].to_s).not_to start_with('2024-01-01')

    migration.migrate(:up)
    expect(connection.select_all('SELECT feature_flags, updated_at FROM accounts ORDER BY id').to_a).to eq(before_retry)
  end

  it 'enables the same bit on an already-upgraded schema without changing other flags on retry' do
    account_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, created_at, updated_at)
      VALUES ('Existing', 8, NOW(), '2024-01-01') RETURNING id
    SQL

    2.times { migration.migrate(:up) }

    row = connection.select_one("SELECT feature_flags, updated_at FROM accounts WHERE id = #{account_id}")
    expect(row['feature_flags'].to_i).to eq(captain_tasks_flag | 8)
    expect(row['updated_at'].to_s).not_to start_with('2024-01-01')
  end
end
