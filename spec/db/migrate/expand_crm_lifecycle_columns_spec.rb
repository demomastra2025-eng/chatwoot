require 'rails_helper'
require Rails.root.join('db/migrate/20261004120000_expand_crm_lifecycle_columns')

RSpec.describe ExpandCrmLifecycleColumns, :crm_lifecycle_ddl do
  def columns_of(table)
    db.columns(table).index_by(&:name)
  end

  it 'adds the lifecycle columns to a PROD-shaped database without indexes, keys or checks' do
    expected_columns = CrmLifecycleMigrationHelper::ADDED_COLUMNS
    revert_to_prod_shape!
    expected_columns.each { |table, names| expect(columns_of(table).keys & names).to be_empty }

    run_migration(:columns)

    expected_columns.each { |table, names| expect(columns_of(table).keys).to include(*names) }
    expect(columns_of('crm_tasks')['schedule_timezone']).to have_attributes(default: 'Asia/Almaty', null: false)
    expect(columns_of('crm_tasks')['all_day']).to have_attributes(default: 'false', null: false)
    expect(columns_of('crm_events')['publication_next_attempt_at']).to have_attributes(null: false)
    expect(columns_of('crm_events')['published_at']).to have_attributes(null: true, default: nil)
  end

  it 'adds no foreign key, check or index with the columns' do
    revert_to_prod_shape!

    run_migration(:columns)

    expect(db.foreign_keys(:crm_tasks).map(&:column)).not_to include('task_type_id', 'completed_by_id')
    expect(db.check_constraints(:crm_tasks).map(&:name)).not_to include('crm_tasks_deadline_shape')
    expect(db.indexes(:crm_tasks).map(&:name)).not_to include('index_crm_tasks_on_task_type_id')
    expect(db.indexes(:crm_events).map(&:name)).not_to include('index_crm_events_on_unpublished')
  end

  it 'records the cutover of each column group before the columns appear' do
    revert_to_prod_shape!
    before = Time.current.change(usec: 0)

    run_migration(:columns)

    %w[crm_tasks_schedule_cutover crm_events_envelope_cutover].each do |key|
      expect(Time.iso8601(metadata(key))).to be_between(before, Time.current)
    end
  end

  it 'records the epoch when the columns already exist, so no live row is ever treated as history' do
    db.execute("DELETE FROM ar_internal_metadata WHERE key LIKE 'crm_%'")

    run_migration(:columns)

    expect(Time.iso8601(metadata('crm_tasks_schedule_cutover'))).to eq(Time.at(0).utc)
    expect(Time.iso8601(metadata('crm_events_envelope_cutover'))).to eq(Time.at(0).utc)
  end

  it 'is idempotent and keeps the first cutover on a re-run' do
    revert_to_prod_shape!
    run_migration(:columns)
    first = [metadata('crm_tasks_schedule_cutover'), metadata('crm_events_envelope_cutover')]
    snapshot = crm_schema_snapshot

    run_migration(:columns, times: 2)

    expect([metadata('crm_tasks_schedule_cutover'), metadata('crm_events_envelope_cutover')]).to eq(first)
    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'moves a recorded cutover forward while the columns are still missing' do
    revert_to_prod_shape!
    set_metadata('crm_events_envelope_cutover', '2020-01-01T00:00:00.000000Z')

    run_migration(:columns)

    expect(Time.iso8601(metadata('crm_events_envelope_cutover'))).to be > Time.utc(2025)
  end

  it 'retries a lock timeout and gives up after five attempts' do
    revert_to_prod_shape!
    migration = described_class.new
    allow(migration).to receive(:sleep)
    attempts = 0
    allow(migration).to receive(:add_task_columns) do
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, 'canceling statement due to lock timeout' if attempts < 3
    end
    ActiveRecord::Migration.suppress_messages { migration.up }
    expect(attempts).to eq(3)

    always_locked = described_class.new
    allow(always_locked).to receive(:sleep)
    allow(always_locked).to receive(:add_task_columns).and_raise(ActiveRecord::LockWaitTimeout)
    expect { ActiveRecord::Migration.suppress_messages { always_locked.up } }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(always_locked).to have_received(:add_task_columns).exactly(described_class::LOCK_ATTEMPTS).times
  end

  it 'sets a lock timeout inside each short transaction' do
    revert_to_prod_shape!
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String)
      original.call(sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements.count { |sql| sql.include?("SET LOCAL lock_timeout = '5s'") }).to eq(4)
  end

  it 'refuses to run before the correlation id column of the earlier migration exists' do
    db.execute('ALTER TABLE crm_events DROP COLUMN correlation_id CASCADE')
    reset_crm_schema_caches

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.up } }
      .to raise_error(ActiveRecord::MigrationError, /correlation_id must exist/)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
