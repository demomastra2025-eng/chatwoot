require 'rails_helper'
require Rails.root.join('db/migrate/20261004193100_add_idempotency_key_to_reminders')

RSpec.describe AddIdempotencyKeyToReminders, :crm_lifecycle_ddl do
  let(:index_name) { described_class::INDEX_NAME }

  def reminders_index
    db.indexes(:reminders).find { |index| index.name == index_name }
  end

  def reminders_without_idempotency_key
    db.remove_index(:reminders, name: index_name)
    db.remove_column(:reminders, :idempotency_key)
    reset_crm_schema_caches
    db.schema_cache.clear_data_source_cache!('reminders')
  end

  it 'adds the column under a lock timeout and builds the unique partial index concurrently' do
    reminders_without_idempotency_key
    algorithms = []
    statements = []
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      algorithms << options[:algorithm]
      original.call(*args, **options.except(:algorithm))
    end
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String)
      original.call(sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(algorithms).to eq([:concurrently])
    expect(statements).to include("SET LOCAL lock_timeout = '5s'")
    expect(reminders_index).to have_attributes(columns: %w[account_id idempotency_key], unique: true)
    expect(reminders_index.where).to match(/idempotency_key\s+IS\s+NOT\s+NULL/i)
  end

  it 'is idempotent' do
    reminders_without_idempotency_key
    run_migration(:reminders)
    snapshot = db.select_rows("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'reminders' ORDER BY 1")

    run_migration(:reminders, times: 2)

    expect(db.select_rows("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'reminders' ORDER BY 1")).to eq(snapshot)
  end

  it 'rebuilds an INVALID index left by an interrupted build instead of failing the deploy' do
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = '#{index_name}'::regclass")
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String) && sql.include?('REINDEX')
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements).to eq(["REINDEX INDEX CONCURRENTLY \"#{index_name}\""])
    expect(invalid_indexes).to be_empty
  end

  it 'retries a lock timeout on the column and gives up after five attempts' do
    reminders_without_idempotency_key
    migration = described_class.new
    allow(migration).to receive(:sleep)
    allow(db).to receive(:add_column).and_raise(ActiveRecord::LockWaitTimeout)

    expect { ActiveRecord::Migration.suppress_messages { migration.up } }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(db).to have_received(:add_column).exactly(described_class::LOCK_ATTEMPTS).times
  end

  it 'refuses an index that does not match the contract' do
    db.remove_index(:reminders, name: index_name)
    db.add_index(:reminders, %i[account_id idempotency_key], unique: true, name: index_name)

    expect { run_migration(:reminders) }
      .to raise_error(ActiveRecord::MigrationError, /does not match the reminder idempotency contract/)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
