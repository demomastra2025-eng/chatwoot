# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261027120000_enable_communication_threads_default_feature_flag')

RSpec.describe EnableCommunicationThreadsDefaultFeatureFlag do
  let(:migration) { described_class.new }
  let(:config) { InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS') }

  before do
    InstallationConfig.where(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').delete_all
    create(
      :installation_config,
      name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS',
      value: [
        { 'name' => 'communication_threads', 'enabled' => false },
        { 'name' => 'scheduling', 'enabled' => true }
      ]
    )
  end

  it 'turns the default on for new accounts and leaves the other defaults and the accounts that exist alone' do
    existing_account = create(:account)

    migration.up

    expect(config.value).to contain_exactly(
      { 'name' => 'communication_threads', 'enabled' => true },
      { 'name' => 'scheduling', 'enabled' => true }
    )
    expect(existing_account.reload.feature_enabled?('communication_threads')).to be(false)
    expect(create(:account).feature_enabled?('communication_threads')).to be(true)
  end

  it 'is safe to replay and can be undone' do
    migration.up
    expect { migration.up }.not_to(change { config.reload.updated_at })

    migration.down
    expect(config.reload.value.find { |feature| feature['name'] == 'communication_threads' }['enabled']).to be(false)
  end

  it 'does nothing on an installation that has no defaults yet' do
    InstallationConfig.where(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').delete_all

    expect { migration.up }.not_to change(InstallationConfig, :count)
  end
end
