require 'rails_helper'
require Rails.root.join('db/migrate/20260309110200_add_feature_flags_overflow_to_accounts')

RSpec.describe AddFeatureFlagsOverflowToAccounts do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:legacy_flags) { (1 << 62) | 8 }

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

  it 'adds the overflow column on an empty historical schema without loading the current Account model' do
    expect(Account).not_to receive(:find_each)
    use_historical_accounts_table

    2.times { migration.migrate(:up) }

    expect(connection.column_exists?(:accounts, :feature_flags_overflow)).to be(true)
    expect(connection.select_value('SELECT COUNT(*) FROM accounts').to_i).to eq(0)
  end

  it 'enables both scheduling flags for existing historical accounts and preserves the bitmask on retry' do
    expect(Account).not_to receive(:find_each)
    use_historical_accounts_table
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) SELECT #{legacy_flags}, '2024-01-01' FROM generate_series(1, 101)")
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) VALUES (16, '2024-01-01')")

    migration.migrate(:up)
    rows = connection.select_all('SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a
    expect(rows.first(101).map { |row| row['feature_flags'].to_i }.uniq).to eq([legacy_flags])
    expect(rows.first(101).map { |row| JSON.parse(row['feature_flags_overflow']) }.uniq).to eq([%w[scheduling scheduling_finance]])
    expect(rows.last['feature_flags'].to_i).to eq(16)
    expect(JSON.parse(rows.last['feature_flags_overflow'])).to eq(%w[scheduling scheduling_finance])
    expect(rows.first['updated_at'].to_s).not_to start_with('2024-01-01')

    migration.migrate(:up)
    expect(connection.select_all('SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a).to eq(rows)
  end

  it 'refuses a historical rollback that would discard enabled overflow flags' do
    use_historical_accounts_table
    connection.execute("INSERT INTO accounts (feature_flags, updated_at) VALUES (#{legacy_flags}, '2024-01-01')")

    migration.migrate(:up)
    2.times do
      expect { migration.migrate(:down) }
        .to raise_error(ActiveRecord::IrreversibleMigration, /Cannot safely discard account overflow flags/)
    end
    expect(connection.column_exists?(:accounts, :feature_flags_overflow)).to be(true)
    expect(connection.select_value('SELECT feature_flags FROM accounts').to_i).to eq(legacy_flags)
    migration.migrate(:up)
    expect(JSON.parse(connection.select_value('SELECT feature_flags_overflow FROM accounts'))).to eq(%w[scheduling scheduling_finance])
    expect(connection.select_value('SELECT feature_flags FROM accounts').to_i).to eq(legacy_flags)
  end

  it 'keeps unrelated installed overflow flags, already-enabled names, bitmasks, and unchanged timestamps' do
    expect(Account).not_to receive(:find_each)
    partially_enabled_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, feature_flags_overflow, created_at, updated_at)
      VALUES ('Partial', #{legacy_flags}, '["other", "scheduling"]', NOW(), '2024-01-01') RETURNING id
    SQL
    enabled_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, feature_flags_overflow, created_at, updated_at)
      VALUES ('Enabled', 16, '["scheduling_finance", "other", "scheduling"]', NOW(), '2024-01-01') RETURNING id
    SQL

    2.times { migration.migrate(:up) }

    partial = connection.select_one("SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts WHERE id = #{partially_enabled_id}")
    expect(partial['feature_flags'].to_i).to eq(legacy_flags)
    expect(JSON.parse(partial['feature_flags_overflow'])).to eq(%w[other scheduling scheduling_finance])
    expect(partial['updated_at'].to_s).not_to start_with('2024-01-01')

    enabled = connection.select_one("SELECT feature_flags, feature_flags_overflow, updated_at FROM accounts WHERE id = #{enabled_id}")
    expect(enabled['feature_flags'].to_i).to eq(16)
    expect(JSON.parse(enabled['feature_flags_overflow'])).to eq(%w[scheduling_finance other scheduling])
    expect(enabled['updated_at'].to_s).to start_with('2024-01-01')
  end

  it 'refuses to drop unrelated installed overflow flags on rollback' do
    account_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, feature_flags, feature_flags_overflow, created_at, updated_at)
      VALUES ('Installed', #{legacy_flags}, '["other", "scheduling"]', NOW(), '2024-01-01') RETURNING id
    SQL

    migration.migrate(:up)
    expect { migration.migrate(:down) }
      .to raise_error(ActiveRecord::IrreversibleMigration, /Cannot safely discard account overflow flags/)

    row = connection.select_one("SELECT feature_flags, feature_flags_overflow FROM accounts WHERE id = #{account_id}")
    expect(row['feature_flags'].to_i).to eq(legacy_flags)
    expect(JSON.parse(row['feature_flags_overflow'])).to eq(%w[other scheduling scheduling_finance])
  end
end
