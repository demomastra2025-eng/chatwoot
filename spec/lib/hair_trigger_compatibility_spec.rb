require 'rails_helper'

RSpec.describe HairTrigger do
  it 'uses the Rails migration pool to read applied and pending migrations' do
    pool = ActiveRecord::Tasks::DatabaseTasks.migration_connection_pool
    migrator = described_class.migrator

    expect(migrator.migrated).to eq(pool.schema_migration.integer_versions.to_set)
    expect(migrator.migrations.map(&:version)).to eq(pool.migration_context.migrations.map(&:version))
  end

  it 'runs only the pool-based Rails schema dump task' do
    Rails.application.load_tasks

    actions = Rake::Task['db:schema:dump'].actions
    expect(actions.size).to eq(1)
    expect(actions.first.source_location.first).to include('/active_record/railties/databases.rake')
  end
end
