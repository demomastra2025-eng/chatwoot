require 'rails_helper'
require Rails.root.join('db/migrate/20260320074636_backfill_feature_contact_attributes_for_assistants')

RSpec.describe BackfillFeatureContactAttributesForAssistants do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:captain_v2_flag) { 1 << 46 } # Position 47 in Featurable's preserved bitmask.

  before do
    allow(ChatwootApp).to receive(:enterprise?).and_return(true)
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE accounts (
        id bigint PRIMARY KEY,
        feature_flags bigint NOT NULL DEFAULT 0,
        feature_flags_overflow jsonb NOT NULL DEFAULT '[]'::jsonb
      ) ON COMMIT DROP
    SQL
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE captain_assistants (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        config jsonb NOT NULL DEFAULT '{}'::jsonb,
        updated_at timestamp NOT NULL DEFAULT NOW()
      ) ON COMMIT DROP
    SQL
    connection.execute('CREATE TEMP TABLE schema_migrations (version varchar PRIMARY KEY) ON COMMIT DROP')
  end

  after do
    %w[captain_assistants accounts schema_migrations].each do |table|
      connection.execute("DROP TABLE IF EXISTS pg_temp.#{table}")
    end
    connection.schema_cache.clear!
    Account.reset_column_information
  end

  it 'works on an empty historical schema without loading current models' do
    2.times { migration.migrate(:up) }
    expect(connection.select_value('SELECT COUNT(*) FROM captain_assistants').to_i).to eq(0)
  end

  it 'fills only missing v2 keys; preserves explicit values, v1 accounts, other flags, and timestamps on retry' do
    connection.execute(<<~SQL.squish)
      INSERT INTO accounts (id, feature_flags, feature_flags_overflow)
      VALUES (1, #{captain_v2_flag}, '["scheduling"]'), (2, 0, '["scheduling_finance"]')
    SQL
    connection.execute(<<~SQL.squish)
      INSERT INTO captain_assistants (id, account_id, config, updated_at) VALUES
        (1, 1, '{"feature_faq": true}', '2024-01-01'),
        (2, 1, '{"feature_contact_attributes": true}', '2024-01-01'),
        (3, 1, '{"feature_contact_attributes": false}', '2024-01-01'),
        (4, 1, '{"feature_contact_attributes": null}', '2024-01-01'),
        (5, 2, '{"feature_faq": true}', '2024-01-01')
    SQL

    migration.migrate(:up)
    rows = connection.select_all('SELECT id, config, updated_at FROM captain_assistants ORDER BY id').to_a
    configs = rows.map { |row| JSON.parse(row['config']) }
    expected_configs = [
      { 'feature_faq' => true, 'feature_contact_attributes' => true },
      { 'feature_contact_attributes' => true },
      { 'feature_contact_attributes' => false },
      { 'feature_contact_attributes' => nil },
      { 'feature_faq' => true }
    ]
    expect(configs).to eq(expected_configs)
    expect(rows.first['updated_at'].to_s).not_to start_with('2024-01-01')
    expect(rows.drop(1).map { |row| row['updated_at'].to_s }).to all(start_with('2024-01-01'))
    expected_accounts = [
      { 'feature_flags' => captain_v2_flag, 'feature_flags_overflow' => '["scheduling"]' },
      { 'feature_flags' => 0, 'feature_flags_overflow' => '["scheduling_finance"]' }
    ]
    expect(connection.select_all('SELECT feature_flags, feature_flags_overflow FROM accounts ORDER BY id').to_a)
      .to eq(expected_accounts)

    migration.migrate(:up)
    expect(connection.select_all('SELECT id, config, updated_at FROM captain_assistants ORDER BY id').to_a).to eq(rows)
  end

  it 'does not recreate removed legacy config on an installation with the later cleanup already applied' do
    connection.execute("INSERT INTO schema_migrations (version) VALUES ('20260406143000')")
    connection.execute("INSERT INTO accounts (id, feature_flags) VALUES (1, #{captain_v2_flag})")
    connection.execute("INSERT INTO captain_assistants (id, account_id, config) VALUES (1, 1, '{\"feature_faq\": true}')")

    2.times { migration.migrate(:up) }
    expect(JSON.parse(connection.select_value('SELECT config FROM captain_assistants WHERE id = 1'))).to eq('feature_faq' => true)
  end

  it 'does not backfill on a community installation' do
    allow(ChatwootApp).to receive(:enterprise?).and_return(false)
    connection.execute("INSERT INTO accounts (id, feature_flags) VALUES (1, #{captain_v2_flag})")
    connection.execute('INSERT INTO captain_assistants (id, account_id) VALUES (1, 1)')

    migration.migrate(:up)
    migration.migrate(:down)
    expect(JSON.parse(connection.select_value('SELECT config FROM captain_assistants WHERE id = 1'))).to eq({})
  end

  it 'rejects a rollback that cannot distinguish newly backfilled from pre-existing true values' do
    connection.execute("INSERT INTO accounts (id, feature_flags) VALUES (1, #{captain_v2_flag})")
    connection.execute('INSERT INTO captain_assistants (id, account_id) VALUES (1, 1)')
    migration.migrate(:up)

    expect { migration.migrate(:down) }
      .to raise_error(ActiveRecord::IrreversibleMigration, /Cannot safely revert assistant contact attribute flags/)
    expect(JSON.parse(connection.select_value('SELECT config FROM captain_assistants WHERE id = 1')))
      .to eq('feature_contact_attributes' => true)
  end
end
