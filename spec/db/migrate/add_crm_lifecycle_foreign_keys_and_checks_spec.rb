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
    expect(foreign_key(:crm_stage_visits, :pipeline_id).on_delete).to eq(:nullify)
    expect(foreign_key(:crm_stage_visits, :stage_id).on_delete).to eq(:nullify)
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

  # A CHECK accepts a row whose expression is UNKNOWN. These rows are the NULL counterexamples of the completeness
  # checks: every one is inserted for real and PostgreSQL itself has to refuse it.
  describe 'completeness checks and NULL' do
    def insert_copy(table, source_id, overrides)
      columns = db.columns(table).map(&:name) - ['id']
      select_list = columns.map { |column| overrides.fetch(column) { db.quote_column_name(column) } }
      db.execute(<<~SQL.squish)
        INSERT INTO #{table} (#{columns.map { |column| db.quote_column_name(column) }.join(', ')})
        SELECT #{select_list.join(', ')} FROM #{table} WHERE id = #{source_id}
      SQL
    end

    def insert_stage_visit(deal, overrides = {})
      values = {
        'account_id' => deal.account_id, 'deal_id' => deal.id, 'pipeline_id' => deal.pipeline_id,
        'stage_id' => deal.stage_id, 'entered_at' => 'now()', 'reliable_since' => 'now()',
        'pipeline_name' => "'Sales'", 'stage_name' => "'Won'", 'stage_outcome' => "'won'",
        'created_at' => 'now()', 'updated_at' => 'now()'
      }.merge(overrides)
      db.execute("INSERT INTO crm_stage_visits (#{values.keys.join(', ')}) VALUES (#{values.values.join(', ')})")
    end

    def rejected_by(constraint, &)
      expect { db.transaction(requires_new: true, &) }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::CheckViolation.*#{constraint}/m)
    end

    def accepted(&)
      expect { db.transaction(requires_new: true, &) }.not_to raise_error
    end

    def expect_null_counterexamples_rejected(task, deal)
      rejected_by('crm_tasks_cancellation_state_complete') do
        insert_copy('crm_tasks', task.id, 'cancelled_at' => 'now()', 'cancellation_reason' => 'NULL')
      end
      rejected_by('crm_deals_waiting_state_complete') do
        insert_copy('crm_deals', deal.id, 'waiting_until' => "now() + interval '1 day'",
                                          'waiting_started_at' => 'now()', 'waiting_reason' => 'NULL')
      end
      rejected_by('crm_stage_visits_terminal_attribution_valid') do
        insert_stage_visit(deal, 'owner_id_at_terminal' => deal.account_id, 'terminal_attribution_version' => 'NULL')
      end
    end

    def expect_complete_rows_accepted(task, deal)
      accepted do
        insert_copy('crm_tasks', task.id, 'cancelled_at' => 'now()', 'cancellation_reason' => "'Duplicate'")
      end
      accepted do
        insert_copy('crm_deals', deal.id, 'waiting_until' => "now() + interval '1 day'",
                                          'waiting_started_at' => 'now()', 'waiting_reason' => "'Documents'")
      end
      accepted { insert_stage_visit(deal, 'terminal_attribution_version' => '1') }
    end

    it 'rejects the NULL counterexamples once the migration has added the checks' do
      task = create(:crm_task)
      deal = create(:crm_deal)
      prepare_prod_shape
      run_migration(:constraints)

      expect_null_counterexamples_rejected(task, deal)
      expect_complete_rows_accepted(task, deal)
    end

    it 'rejects the NULL counterexamples on the final schema as well' do
      task = create(:crm_task)
      deal = create(:crm_deal)

      expect_null_counterexamples_rejected(task, deal)
      expect_complete_rows_accepted(task, deal)
    end
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
