require 'rails_helper'
require Rails.root.join('db/migrate/20261004120100_create_crm_lifecycle_tables')

RSpec.describe CreateCrmLifecycleTables, :crm_lifecycle_ddl do
  let(:new_tables) { CrmLifecycleMigrationHelper::NEW_TABLES }

  it 'creates the new tables without foreign keys and without the stage visit indexes' do
    revert_to_prod_shape!
    new_tables.each { |table| expect(db.table_exists?(table)).to be(false) }

    run_migration(:tables)

    new_tables.each do |table|
      expect(db.table_exists?(table)).to be(true)
      expect(db.foreign_keys(table)).to be_empty
    end
    expect(db.indexes(:crm_task_types).map(&:name)).to include(
      'index_crm_task_types_on_account_id_and_code', 'index_crm_task_types_on_account_default'
    )
    expect(db.indexes(:crm_task_outcomes).map(&:name)).to include('index_crm_task_outcomes_on_type_default')
    expect(db.indexes(:crm_stage_visits)).to be_empty
    expect(db.columns(:crm_stage_visits).find { |column| column.name == 'correlation_id' }.default_function)
      .to eq('gen_random_uuid()')
  end

  it 'is idempotent' do
    revert_to_prod_shape!
    run_migration(:tables)
    snapshot = crm_schema_snapshot

    run_migration(:tables, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'upgrades an aset-shaped stage visit table without changing its rows' do
    account = create(:account)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    first_entered_at = Time.utc(2024, 1, 3, 9)
    closed_at = Time.utc(2024, 1, 5, 12, 30)
    create(:crm_stage_visit, deal: deal, entered_at: first_entered_at, exited_at: closed_at,
                             reliable_since: first_entered_at, correlation_id: '96000451-0000-4000-8000-000000000001')
    create(:crm_stage_visit, deal: deal, entered_at: closed_at, reliable_since: closed_at,
                             correlation_id: '96000452-0000-4000-8000-000000000002')
    rows_before = db.select_rows('SELECT id, deal_id, entered_at, exited_at, correlation_id FROM crm_stage_visits ORDER BY id')
    db.remove_check_constraint(:crm_stage_visits, name: 'crm_stage_visits_terminal_attribution_valid')
    %i[owner_id_at_terminal team_id_at_terminal terminal_attribution_version].each do |column|
      db.remove_column(:crm_stage_visits, column)
    end
    db.change_column_default(:crm_stage_visits, :correlation_id, nil)
    reset_crm_schema_caches

    run_migration(:tables, times: 2)

    expect(db.select_rows('SELECT id, deal_id, entered_at, exited_at, correlation_id FROM crm_stage_visits ORDER BY id'))
      .to eq(rows_before)
    columns = db.columns(:crm_stage_visits).index_by(&:name)
    attribution = columns.values_at('owner_id_at_terminal', 'team_id_at_terminal', 'terminal_attribution_version')
    expect(attribution.map(&:sql_type)).to eq(%w[bigint bigint integer])
    expect(attribution.map(&:null)).to eq([true, true, true])
    expect(columns['correlation_id'].default_function).to eq('gen_random_uuid()')
  end

  it 'refuses an existing stage visit table that lacks core columns' do
    db.remove_column(:crm_stage_visits, :reliable_since)
    reset_crm_schema_caches

    expect { run_migration(:tables) }.to raise_error(ActiveRecord::MigrationError, /missing required columns: reliable_since/)
  end

  it 'refuses an unexpected correlation id default' do
    db.change_column_default(:crm_stage_visits, :correlation_id, -> { 'md5(random()::text)::uuid' })
    reset_crm_schema_caches

    expect { run_migration(:tables) }.to raise_error(RuntimeError, /Unexpected crm_stage_visits.correlation_id default/)
  end

  it 'never half-creates a table: a failure while indexing rolls the table back' do
    revert_to_prod_shape!
    migration = described_class.new
    allow(db).to receive(:add_index).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect { ActiveRecord::Migration.suppress_messages { migration.up } }.to raise_error(ActiveRecord::StatementInvalid)
    expect(db.table_exists?(:crm_task_types)).to be(false)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
