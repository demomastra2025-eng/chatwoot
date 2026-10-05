require 'rails_helper'
require Rails.root.join('db/migrate/20261004120400_add_crm_lifecycle_indexes')

RSpec.describe AddCrmLifecycleIndexes, :crm_lifecycle_ddl do
  let(:index_names) do
    described_class::INDEXES.map { |table, columns, options| options[:name] || db.index_name(table, columns) }
  end

  def present_index_names
    quoted = index_names.map { |name| db.quote(name) }.join(', ')
    db.select_values("SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND indexname IN (#{quoted})")
  end

  def prepare_prod_shape
    revert_to_prod_shape!
    run_chain(:columns, :tables, :constraints)
  end

  it 'builds every index of the series with the schema.rb names' do
    expected = crm_schema_snapshot[:indexes]
    prepare_prod_shape
    already_there = present_index_names
    expect(index_names - already_there).to include('index_crm_tasks_on_task_type_id', 'index_crm_events_on_unpublished')

    run_migration(:indexes)

    expect(present_index_names).to match_array(index_names)
    expect(invalid_indexes).to be_empty
    exit_window = 'index_crm_stage_visits_on_account_id_and_exited_at'
    expect(crm_schema_snapshot[:indexes]).to eq(expected.reject { |_table, name, _definition| name == exit_window })
  end

  it 'asks for CONCURRENTLY builds' do
    prepare_prod_shape
    algorithms = []
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      algorithms << options[:algorithm]
      original.call(*args, **options.except(:algorithm))
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(algorithms).to eq([:concurrently] * described_class::INDEXES.size)
  end

  it 'is idempotent' do
    prepare_prod_shape
    run_migration(:indexes)
    snapshot = crm_schema_snapshot

    run_migration(:indexes, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'rebuilds an index that an interrupted concurrent build left INVALID instead of accepting it' do
    prepare_prod_shape
    run_migration(:indexes)
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = 'index_crm_events_on_command_dedupe'::regclass")
    expect(invalid_indexes).to eq(['index_crm_events_on_command_dedupe'])
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String) && sql.include?('REINDEX')
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements).to eq(['REINDEX INDEX CONCURRENTLY "index_crm_events_on_command_dedupe"'])
    expect(invalid_indexes).to be_empty
  end

  it 'lifts the request statement timeout for the builds and restores it afterwards' do
    prepare_prod_shape
    original_timeout = db.select_value('SHOW statement_timeout')
    seen = []
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      seen << db.select_value('SHOW statement_timeout')
      original.call(*args, **options.except(:algorithm))
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(seen.uniq).to eq(['30min'])
    expect(db.select_value('SHOW statement_timeout')).to eq(original_timeout)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
