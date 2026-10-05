require 'rails_helper'
require Rails.root.join('db/migrate/20261004120200_add_crm_lifecycle_foreign_keys_and_checks')

RSpec.describe AddCrmLifecycleForeignKeysAndChecks, :crm_lifecycle_ddl do
  def foreign_key(table, column)
    db.foreign_keys(table).find { |candidate| candidate.column == column.to_s }
  end

  def check_constraint(table, name)
    db.check_constraints(table).find { |candidate| candidate.name == name }
  end

  def prepare_prod_shape
    revert_to_prod_shape!
    run_chain(:columns, :tables)
  end

  it 'adds every foreign key and check as NOT VALID' do
    prepare_prod_shape

    run_migration(:constraints)

    described_class::FOREIGN_KEYS.each do |table, to_table, options|
      key = foreign_key(table, options.fetch(:column))
      expect(key).to be_present, "#{table}.#{options[:column]} has no foreign key"
      expect(key.to_table).to eq(to_table.to_s)
      expect(key.validated?).to be(false)
    end
    expect(foreign_key(:crm_tasks, :completed_by_id).on_delete).to eq(:nullify)
    described_class::CHECK_CONSTRAINTS.each do |table, name, _expression|
      expect(check_constraint(table, name)).to be_present
      expect(check_constraint(table, name).validate?).to be(false)
    end
  end

  it 'is idempotent' do
    prepare_prod_shape
    run_migration(:constraints)
    snapshot = crm_schema_snapshot

    run_migration(:constraints, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'leaves keys and checks that already exist (a DEV-shaped database) untouched and validated' do
    snapshot = crm_schema_snapshot

    run_migration(:constraints)

    expect(crm_schema_snapshot).to eq(snapshot)
    expect(unvalidated_constraints).to be_empty
  end

  it 'adds the keys on top of rows that would fail validation, so the scan happens later' do
    task = create(:crm_task)
    prepare_prod_shape
    db.execute("UPDATE crm_tasks SET task_type_id = 987654321 WHERE id = #{task.id}")

    expect { run_migration(:constraints) }.not_to raise_error
    expect(foreign_key(:crm_tasks, :task_type_id).validated?).to be(false)
  end

  it 'retries a lock timeout per statement and gives up after five attempts' do
    prepare_prod_shape
    migration = described_class.new
    allow(migration).to receive(:sleep)
    attempts = 0
    allow(db).to receive(:add_foreign_key).and_wrap_original do |original, *args, **options|
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, 'lock timeout' if attempts == 1

      original.call(*args, **options)
    end

    ActiveRecord::Migration.suppress_messages { migration.up }

    expect(attempts).to eq(described_class::FOREIGN_KEYS.size + 1)

    stuck = described_class.new
    allow(stuck).to receive(:sleep)
    allow(db).to receive(:add_check_constraint).and_raise(ActiveRecord::LockWaitTimeout)
    db.execute('ALTER TABLE crm_tasks DROP CONSTRAINT crm_tasks_deadline_shape')
    expect { ActiveRecord::Migration.suppress_messages { stuck.up } }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(db).to have_received(:add_check_constraint).exactly(described_class::LOCK_ATTEMPTS).times
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
