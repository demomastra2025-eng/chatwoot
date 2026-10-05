require 'rails_helper'
require Rails.root.join('db/migrate/20261004120500_validate_crm_lifecycle_constraints')

RSpec.describe ValidateCrmLifecycleConstraints, :crm_lifecycle_ddl do
  def prepare_not_valid_database
    revert_to_prod_shape!
    run_chain(:columns, :tables, :constraints)
  end

  it 'validates every foreign key and check that the earlier step left NOT VALID' do
    prepare_not_valid_database
    expect(unvalidated_constraints.size).to eq(
      AddCrmLifecycleForeignKeysAndChecks::FOREIGN_KEYS.size + AddCrmLifecycleForeignKeysAndChecks::CHECK_CONSTRAINTS.size
    )

    run_migration(:validate)

    expect(unvalidated_constraints).to be_empty
  end

  it 'is idempotent and changes nothing on a database whose constraints are already valid' do
    snapshot = crm_schema_snapshot

    run_migration(:validate, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'fails on a row that violates a key, leaving the key NOT VALID for a later run' do
    task = create(:crm_task)
    revert_to_prod_shape!
    run_chain(:columns, :tables)
    db.execute("UPDATE crm_tasks SET task_type_id = 987654321 WHERE id = #{task.id}")
    run_chain(:constraints)

    expect { db.transaction(requires_new: true) { run_migration(:validate) } }.to raise_error(ActiveRecord::StatementInvalid)
    expect(db.foreign_keys(:crm_tasks).find { |key| key.column == 'task_type_id' }.validated?).to be(false)
  end

  it 'lifts the request statement timeout for the scans and restores it afterwards' do
    prepare_not_valid_database
    original_timeout = db.select_value('SHOW statement_timeout')
    seen = []
    allow(db).to receive(:validate_foreign_key).and_wrap_original do |original, *args, **options|
      seen << db.select_value('SHOW statement_timeout')
      original.call(*args, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(seen.uniq).to eq(['30min'])
    expect(db.select_value('SHOW statement_timeout')).to eq(original_timeout)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
