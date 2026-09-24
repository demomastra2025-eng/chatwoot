require 'rails_helper'
require Rails.root.join('db/migrate/20250421085134_update_auto_resolve_to_mminutes')

RSpec.describe UpdateAutoResolveToMminutes do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    connection.execute('DROP TABLE IF EXISTS pg_temp.accounts')
    connection.schema_cache.clear!
    Account.reset_column_information
  end

  def use_historical_accounts_table
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE accounts (
        id bigserial PRIMARY KEY,
        auto_resolve_duration integer,
        settings jsonb DEFAULT '{}'::jsonb,
        updated_at timestamp NOT NULL DEFAULT NOW()
      ) ON COMMIT DROP
    SQL
  end

  def historical_rows
    connection.select_all('SELECT settings, updated_at FROM accounts ORDER BY id').to_a.map do |row|
      row['settings'] = JSON.parse(row['settings']) if row['settings']
      row
    end
  end

  it 'migrates a fresh historical database with no accounts, including on retry' do
    use_historical_accounts_table

    2.times { migration.migrate(:up) }

    expect(connection.select_value('SELECT COUNT(*) FROM accounts').to_i).to eq(0)
  end

  it 'converts legacy days to minutes, keeps other settings, and leaves null-duration accounts untouched on retry' do
    use_historical_accounts_table
    connection.execute(<<~SQL.squish)
      INSERT INTO accounts (auto_resolve_duration, settings, updated_at) VALUES
        (3, '{"auto_resolve_after": 60, "message": "keep", "nested": {"enabled": true}}', '2024-01-01'),
        (2, NULL, '2024-01-01'),
        (1, 'null'::jsonb, '2024-01-01'),
        (NULL, '{"auto_resolve_after": 99, "message": "untouched"}', '2024-01-01')
    SQL

    migration.migrate(:up)
    rows = historical_rows

    expect(rows[0]['settings']).to eq('auto_resolve_after' => 4320, 'message' => 'keep', 'nested' => { 'enabled' => true })
    expect(rows[1]['settings']).to eq('auto_resolve_after' => 2880)
    expect(rows[2]['settings']).to eq('auto_resolve_after' => 1440)
    expect(rows[3]['settings']).to eq('auto_resolve_after' => 99, 'message' => 'untouched')
    expect(rows[3]['updated_at'].to_s).to start_with('2024-01-01')

    migration.migrate(:up)
    expect(historical_rows).to eq(rows)
  end

  it 'rejects non-object settings before changing any account, but can retry after the data is repaired' do
    use_historical_accounts_table
    connection.execute(<<~SQL.squish)
      INSERT INTO accounts (auto_resolve_duration, settings, updated_at) VALUES
        (1, '{"message": "keep"}', '2024-01-01'),
        (2, '[]'::jsonb, '2024-01-01'),
        (NULL, '["untouched"]'::jsonb, '2024-01-01')
    SQL
    invalid_id = connection.select_value("SELECT id FROM accounts WHERE settings = '[]'::jsonb")
    unchanged_row = historical_rows[2]
    { '[]' => 'array', '"invalid"' => 'string', '123' => 'number', 'true' => 'boolean' }.each do |json, type|
      connection.execute("UPDATE accounts SET settings = '#{json}'::jsonb WHERE id = #{invalid_id}")
      before = historical_rows

      expect { migration.migrate(:up) }.to raise_error(
        ActiveRecord::MigrationError,
        /account #{invalid_id}: settings must be a JSON object or null \(got #{type}\)/
      )
      expect(historical_rows).to eq(before)
    end

    connection.execute("UPDATE accounts SET settings = '{\"message\": \"repaired\"}'::jsonb WHERE id = #{invalid_id}")
    migration.migrate(:up)
    rows = historical_rows
    expect(rows[0]['settings']).to eq('auto_resolve_after' => 1440, 'message' => 'keep')
    expect(rows[1]['settings']).to eq('auto_resolve_after' => 2880, 'message' => 'repaired')
    expect(rows[2]).to eq(unchanged_row)

    migration.migrate(:up)
    expect(historical_rows).to eq(rows)
  end

  it 'updates already-installed accounts without overwriting unrelated settings, and is repeatable' do
    account_id = connection.select_value(<<~SQL.squish).to_i
      INSERT INTO accounts (name, auto_resolve_duration, settings, created_at, updated_at)
      VALUES ('Existing', 1, '{"auto_resolve_after": 10, "auto_resolve_message": "retain"}', NOW(), '2024-01-01')
      RETURNING id
    SQL

    2.times { migration.migrate(:up) }

    settings = connection.select_value("SELECT settings FROM accounts WHERE id = #{account_id}")
    expect(JSON.parse(settings)).to eq('auto_resolve_after' => 1440, 'auto_resolve_message' => 'retain')
  end
end
