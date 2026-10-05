require 'rails_helper'
require Rails.root.join('db/migrate/20261004193000_create_captain_follow_up_attempts')

# The contract checks of an existing table live in create_captain_follow_up_attempts_spec.rb; this file covers how the
# table, its keys and its indexes are created without a lock queue on conversations and messages.
RSpec.describe CreateCaptainFollowUpAttempts, :crm_lifecycle_ddl do
  let(:table_names) { ['captain_follow_up_attempts'] }

  def foreign_keys
    db.foreign_keys(:captain_follow_up_attempts).index_by(&:column)
  end

  it 'creates the table without keys, then adds each key NOT VALID under a lock timeout and validates it' do
    expected = crm_schema_snapshot(table_names)
    db.execute('DROP TABLE captain_follow_up_attempts CASCADE')
    reset_crm_schema_caches
    statements = []
    created_with_keys = nil
    allow(db).to receive(:create_table).and_wrap_original do |original, *args, **options, &block|
      original.call(*args, **options, &block).tap { created_with_keys = db.foreign_keys(:captain_follow_up_attempts) }
    end
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String)
      original.call(sql, *rest, **options)
    end
    algorithms = []
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      algorithms << options[:algorithm]
      original.call(*args, **options.except(:algorithm))
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(created_with_keys).to be_empty
    expect(statements.count { |sql| sql.include?("SET LOCAL lock_timeout = '5s'") }).to eq(4)
    expect(algorithms.compact).to eq([:concurrently] * 3)
    expect(foreign_keys.values.map(&:validated?)).to all(be(true))
    reset_crm_schema_caches
    expect(crm_schema_snapshot(table_names)).to eq(expected)
  end

  it 'is idempotent' do
    expected = crm_schema_snapshot(table_names)
    db.execute('DROP TABLE captain_follow_up_attempts CASCADE')
    reset_crm_schema_caches

    run_migration(:captain, times: 3)

    expect(crm_schema_snapshot(table_names)).to eq(expected)
  end

  it 'finishes a table whose build was interrupted after the key was added NOT VALID' do
    pristine = crm_schema_snapshot(table_names)
    key = foreign_keys['conversation_id']
    db.remove_foreign_key(:captain_follow_up_attempts, name: key.name)
    db.add_foreign_key(:captain_follow_up_attempts, :conversations,
                       column: :conversation_id, on_delete: :cascade, validate: false, name: key.name)
    db.remove_index(:captain_follow_up_attempts, name: 'index_captain_follow_up_attempts_on_attempt_key')
    expect(crm_schema_snapshot(table_names)).not_to eq(pristine)

    run_migration(:captain)

    expect(crm_schema_snapshot(table_names)).to eq(pristine)
  end

  it 'rebuilds an INVALID index left by an interrupted concurrent build' do
    name = 'index_captain_follow_up_attempts_on_attempt_key'
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = '#{name}'::regclass")
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String) && sql.include?('REINDEX')
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements).to eq(["REINDEX INDEX CONCURRENTLY \"#{name}\""])
    expect(invalid_indexes).to be_empty
  end

  it 'retries a lock timeout on a key and gives up after five attempts' do
    db.execute('ALTER TABLE captain_follow_up_attempts DROP CONSTRAINT ' \
               "#{db.quote_table_name(foreign_keys['account_id'].name)}")
    migration = described_class.new
    allow(migration).to receive(:sleep)
    allow(db).to receive(:add_foreign_key).and_raise(ActiveRecord::LockWaitTimeout)

    expect { ActiveRecord::Migration.suppress_messages { migration.up } }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(db).to have_received(:add_foreign_key).exactly(described_class::LOCK_ATTEMPTS).times
  end
end
