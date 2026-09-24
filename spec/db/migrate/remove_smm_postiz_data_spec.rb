require 'rails_helper'
require Rails.root.join('db/migrate/20260805145118_remove_smm_postiz_data')

RSpec.describe RemoveSmmPostizData do
  let!(:account) { create(:account) }
  let!(:legacy_postiz_hook) { create(:integrations_hook, account: account) }
  let!(:legacy_unknown_hook) { create(:integrations_hook) }
  let!(:other_hook) { create(:integrations_hook) }
  let!(:feature_defaults) do
    InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').tap do |config|
      config.value = [
        { 'name' => 'content', 'enabled' => true },
        { 'name' => 'scheduling', 'enabled' => true }
      ]
      config.save!
    end
  end

  before do
    connection = ActiveRecord::Base.connection
    constraint_name = described_class::POSTIZ_TOMBSTONE_CONSTRAINT
    constraint_exists = connection.check_constraint_exists?(:integrations_hooks, name: constraint_name)
    connection.remove_check_constraint(:integrations_hooks, name: constraint_name) if constraint_exists

    # rubocop:disable Rails/SkipsModelValidations -- seed legacy states rejected by the current model contract.
    account.update_column(:feature_flags_overflow, ['content', 'scheduling_finance', 12, 'content'])
    Integrations::Hook.where(id: legacy_postiz_hook.id).update_all(app_id: 'postiz')
    Integrations::Hook.where(id: legacy_unknown_hook.id).update_all(app_id: 'retired_connector')
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'removes unregistered hooks and stale content flags without changing other data' do
    original_feature_bitmask = account.feature_flags
    original_updated_at = account.reload.updated_at
    migration = described_class.new

    migration.up
    migration.up

    expect(Integrations::Hook.exists?(legacy_postiz_hook.id)).to be(false)
    expect(Integrations::Hook.exists?(legacy_unknown_hook.id)).to be(false)
    expect(Integrations::Hook.exists?(other_hook.id)).to be(true)
    expect(account.reload.feature_flags_overflow).to eq(['scheduling_finance', 12])
    expect([account.feature_flags, account.updated_at]).to eq([original_feature_bitmask, original_updated_at])
    expect(feature_defaults.reload.value.pluck('name')).to eq(['scheduling'])
    expect(ActiveRecord::Base.connection.check_constraint_exists?(:integrations_hooks,
                                                                  name: described_class::POSTIZ_TOMBSTONE_CONSTRAINT)).to be(true)
  end

  it 'removes only content on an older accounts table without instantiating the current Account model' do
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL.squish)
      CREATE TEMP TABLE accounts (
        id bigint PRIMARY KEY,
        feature_flags_overflow jsonb NOT NULL DEFAULT '[]'::jsonb,
        updated_at timestamp NOT NULL DEFAULT '2024-01-01'
      ) ON COMMIT DROP
    SQL
    connection.execute(<<~SQL.squish)
      INSERT INTO accounts (id, feature_flags_overflow) VALUES
        (1, '["content", "scheduling", 12, "content"]'),
        (2, '["scheduling_finance"]'),
        (3, '[]')
    SQL

    expect(Account).not_to receive(:where)
    migration = described_class.new
    migration.up
    rows = connection.select_all('SELECT feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a
    expect(rows.map { |row| JSON.parse(row['feature_flags_overflow']) })
      .to eq([['scheduling', 12], ['scheduling_finance'], []])
    expect(rows.map { |row| row['updated_at'].to_s }).to all(start_with('2024-01-01'))

    migration.up
    expect(connection.select_all('SELECT feature_flags_overflow, updated_at FROM accounts ORDER BY id').to_a).to eq(rows)
  ensure
    connection&.execute('DROP TABLE IF EXISTS pg_temp.accounts')
    connection&.schema_cache&.clear!
    Account.reset_column_information
  end

  it 'removes the tombstone on rollback without restoring deleted credentials' do
    migration = described_class.new

    migration.up
    migration.down

    expect(ActiveRecord::Base.connection.check_constraint_exists?(:integrations_hooks,
                                                                  name: described_class::POSTIZ_TOMBSTONE_CONSTRAINT)).to be(false)
    expect(Integrations::Hook.exists?(legacy_postiz_hook.id)).to be(false)
  end
end
