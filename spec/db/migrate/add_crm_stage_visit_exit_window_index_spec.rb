require 'rails_helper'
require Rails.root.join('db/migrate/20261004121500_add_crm_stage_visit_exit_window_index')

RSpec.describe AddCrmStageVisitExitWindowIndex, :crm_lifecycle_ddl do
  let(:index_name) { described_class::INDEX_NAME }

  def index_row
    db.select_one("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(#{db.quote(index_name)})")
  end

  it 'creates the partial index concurrently and is idempotent' do
    db.remove_index(:crm_stage_visits, name: index_name)
    algorithms = []
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      algorithms << options[:algorithm]
      original.call(*args, **options.except(:algorithm))
    end

    2.times { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

    expect(algorithms).to eq(%i[concurrently concurrently])
    expect(index_row).to eq('indisvalid' => true)
    index = db.indexes(:crm_stage_visits).find { |candidate| candidate.name == index_name }
    expect(index.columns).to eq(%w[account_id exited_at])
    expect(index.where).to match(/exited_at IS NOT NULL/i)
  end

  it 'rebuilds an INVALID index left by an interrupted build instead of accepting it' do
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = '#{index_name}'::regclass")
    plain_concurrent_statements
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String) && sql.include?('REINDEX')
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements).to eq(["REINDEX INDEX CONCURRENTLY \"#{index_name}\""])
    expect(index_row).to eq('indisvalid' => true)
  end

  it 'leaves a valid index alone' do
    plain_concurrent_statements
    statements = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      statements << sql if sql.is_a?(String)
      original.call(sql, *rest, **options)
    end

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(statements.grep(/REINDEX/)).to be_empty
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
