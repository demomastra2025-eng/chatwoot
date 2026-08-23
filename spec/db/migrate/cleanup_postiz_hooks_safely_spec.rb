require 'rails_helper'
require Rails.root.join('db/migrate/20260823140000_cleanup_postiz_hooks_safely')

RSpec.describe CleanupPostizHooksSafely do
  let!(:postiz_hook) { create(:integrations_hook) }
  let!(:unknown_hook) { create(:integrations_hook) }
  let!(:registered_hook) { create(:integrations_hook) }

  before do
    connection = ActiveRecord::Base.connection
    constraint_name = described_class::POSTIZ_TOMBSTONE_CONSTRAINT
    if connection.check_constraint_exists?(:integrations_hooks, name: constraint_name)
      connection.remove_check_constraint(:integrations_hooks, name: constraint_name)
    end

    # rubocop:disable Rails/SkipsModelValidations -- seed legacy states rejected by the current model contract.
    Integrations::Hook.where(id: postiz_hook.id).update_all(app_id: 'postiz')
    Integrations::Hook.where(id: unknown_hook.id).update_all(app_id: 'retired_connector')
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'runs after the historical migration and removes only Postiz hooks' do
    historical_version = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT version
      FROM schema_migrations
      WHERE version = '20260805145118'
    SQL
    expect(historical_version).to eq('20260805145118')

    migration = described_class.new
    migration.up
    migration.up

    expect(Integrations::Hook.exists?(postiz_hook.id)).to be(false)
    expect(Integrations::Hook.exists?(unknown_hook.id)).to be(true)
    expect(Integrations::Hook.exists?(registered_hook.id)).to be(true)
    expect(ActiveRecord::Base.connection.check_constraint_exists?(:integrations_hooks,
                                                                  name: described_class::POSTIZ_TOMBSTONE_CONSTRAINT)).to be(true)
  end
end
