require 'rails_helper'
require Rails.root.join('db/migrate/20250416182131_flip_chatwoot_v4_default_feature_flag_installation_config')

RSpec.describe FlipChatwootV4DefaultFeatureFlagInstallationConfig do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:v4_flag) { 1 << 37 }

  before { allow(GlobalConfig).to receive(:clear_cache) }

  after do
    connection.execute('DROP TABLE IF EXISTS pg_temp.accounts')
    connection.schema_cache.clear!
    Account.reset_column_information
  end

  def use_historical_accounts_table
    connection.execute('CREATE TEMP TABLE accounts (id bigserial PRIMARY KEY, feature_flags bigint DEFAULT 0 NOT NULL) ON COMMIT DROP')
  end

  it 'migrates an empty historical database without an account mode column or installation defaults' do
    use_historical_accounts_table

    2.times { migration.migrate(:up) }

    expect(connection.select_value('SELECT COUNT(*) FROM accounts').to_i).to eq(0)
    expect(GlobalConfig).to have_received(:clear_cache).twice
  end

  it 'enables the historical v4 bit for every existing account and preserves other flags and installation defaults on retry' do
    use_historical_accounts_table
    connection.execute('INSERT INTO accounts (feature_flags) SELECT 8 FROM generate_series(1, 101)')
    connection.execute("INSERT INTO accounts (feature_flags) VALUES (#{v4_flag | 16})")
    config = InstallationConfig.create!(
      name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS',
      value: [
        { 'name' => 'chatwoot_v4', 'enabled' => false, 'premium' => true },
        { 'name' => 'other', 'enabled' => false }
      ]
    )

    2.times { migration.migrate(:up) }

    expect(connection.select_value("SELECT COUNT(*) FROM accounts WHERE feature_flags = #{v4_flag | 8}").to_i).to eq(101)
    expect(connection.select_value("SELECT COUNT(*) FROM accounts WHERE feature_flags = #{v4_flag | 16}").to_i).to eq(1)
    expected_features = [
      { 'name' => 'chatwoot_v4', 'enabled' => true, 'premium' => true },
      { 'name' => 'other', 'enabled' => false }
    ]
    expect(config.reload.value).to eq(expected_features)
  end

  it 'enables the same bit on an upgraded account schema without changing other flags' do
    account_id = connection.select_value(
      "INSERT INTO accounts (name, feature_flags, created_at, updated_at) VALUES ('Existing', 8, NOW(), NOW()) RETURNING id"
    ).to_i

    migration.migrate(:up)
    migration.migrate(:up)

    expect(connection.select_value("SELECT feature_flags FROM accounts WHERE id = #{account_id}").to_i).to eq(v4_flag | 8)
  end
end
