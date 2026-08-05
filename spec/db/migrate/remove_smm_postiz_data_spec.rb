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
    account.update_column(:feature_flags_overflow, %w[content scheduling_finance])
    Integrations::Hook.where(id: legacy_postiz_hook.id).update_all(app_id: 'postiz')
    Integrations::Hook.where(id: legacy_unknown_hook.id).update_all(app_id: 'retired_connector')
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'removes unregistered hooks and stale content flags without changing other data' do
    original_feature_bitmask = account.feature_flags
    migration = described_class.new

    migration.up
    migration.up

    expect(Integrations::Hook.exists?(legacy_postiz_hook.id)).to be(false)
    expect(Integrations::Hook.exists?(legacy_unknown_hook.id)).to be(false)
    expect(Integrations::Hook.exists?(other_hook.id)).to be(true)
    expect(account.reload.feature_flags_overflow).to eq(['scheduling_finance'])
    expect(account.feature_flags).to eq(original_feature_bitmask)
    expect(feature_defaults.reload.value.pluck('name')).to eq(['scheduling'])
    expect(ActiveRecord::Base.connection.check_constraint_exists?(:integrations_hooks,
                                                                  name: described_class::POSTIZ_TOMBSTONE_CONSTRAINT)).to be(true)
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
