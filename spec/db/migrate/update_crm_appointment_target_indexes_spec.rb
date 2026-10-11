require 'rails_helper'
require Rails.root.join('db/migrate/20261011093000_update_crm_appointment_target_indexes')

RSpec.describe UpdateCrmAppointmentTargetIndexes do
  let(:connection) { ActiveRecord::Base.connection }
  let(:account) { create(:account) }
  let(:migration) { described_class.new }

  before do
    # DDL remains transactional in these examples; production builds and drops
    # still request CONCURRENTLY, as checked below.
    allow(connection).to receive(:add_index).and_wrap_original do |original, *args, **options|
      original.call(*args, **options.except(:algorithm))
    end
    allow(connection).to receive(:remove_index).and_wrap_original do |original, *args, **options|
      original.call(*args, **options.except(:algorithm))
    end
    allow(connection).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end
    described_class::INDEXES.each do |name, source_key|
      connection.remove_index :crm_pipelines, name: "#{name}_with_master", if_exists: true
      connection.remove_index :crm_pipelines, name: name, if_exists: true
      connection.add_index :crm_pipelines, :account_id, name: name, unique: true,
                                                     where: "active AND appointment_automation ->> '#{source_key}' = 'true'"
    end
  end

  def set_config(record, config)
    # Bypass callbacks so PostgreSQL itself checks the index semantics.
    record.update_column(:appointment_automation, config)
  end

  def update_indexes
    ActiveRecord::Migration.suppress_messages { migration.up }
  end

  def index_state(name)
    connection.select_one(<<~SQL.squish)
      SELECT indexrelid, indisvalid, pg_get_expr(indpred, indrelid) AS predicate
      FROM pg_index WHERE indexrelid = to_regclass(#{connection.quote(name)})
    SQL
  end

  it 'replaces both legacy predicates concurrently and preserves all pipeline attributes' do
    pipeline = create(:crm_pipeline, account: account)
    config = {
      'auto_create_deals' => false, 'auto_create_from_calendar' => true, 'auto_create_from_medelement' => true,
      'auto_create_from_calendar_enabled_at' => '2026-10-01T00:00:00Z',
      'auto_create_from_medelement_enabled_at' => '2026-10-02T00:00:00Z',
      'rules' => [], 'preserved_metadata' => 'keep'
    }
    set_config(pipeline, config)
    original = pipeline.reload.attributes
    builds = []
    drops = []
    allow(connection).to receive(:add_index).and_wrap_original do |original_method, *args, **options|
      builds << options[:algorithm]
      original_method.call(*args, **options.except(:algorithm))
    end
    allow(connection).to receive(:remove_index).and_wrap_original do |original_method, *args, **options|
      drops << options[:algorithm]
      original_method.call(*args, **options.except(:algorithm))
    end

    update_indexes

    expect(builds).to eq(%i[concurrently concurrently])
    expect(drops).to all(eq(:concurrently))
    expect(pipeline.reload.attributes).to eq(original)
    described_class::INDEXES.each_key do |name|
      expect(index_state(name)).to include('indisvalid' => true)
      expect(index_state(name)['predicate']).to include('auto_create_deals', 'IS DISTINCT FROM')
      expect(index_state("#{name}_with_master")).to be_nil
    end
  end

  UpdateCrmAppointmentTargetIndexes::INDEXES.each do |name, source_key|
    it "allows retained #{source_key} flags under master OFF while enforcing active target uniqueness" do
      update_indexes
      target = create(:crm_pipeline, account: account)
      disabled = create(:crm_pipeline, account: account)
      duplicate = create(:crm_pipeline, account: account)
      enabled_config = { 'auto_create_deals' => true, source_key => true }
      set_config(target, enabled_config)

      expect { set_config(disabled, { 'auto_create_deals' => false, source_key => true }) }.not_to raise_error
      expect do
        ApplicationRecord.transaction(requires_new: true) { set_config(duplicate, enabled_config) }
      end.to raise_error(ActiveRecord::RecordNotUnique, /#{name}/)
      expect(disabled.reload.appointment_automation).to include('auto_create_deals' => false, source_key => true)
    end

    it "keeps legacy #{source_key} targets with an absent master setting unique" do
      update_indexes
      legacy = create(:crm_pipeline, account: account)
      duplicate = create(:crm_pipeline, account: account)
      set_config(legacy, { source_key => true })

      expect do
        ApplicationRecord.transaction(requires_new: true) do
          set_config(duplicate, { 'auto_create_deals' => true, source_key => true })
        end
      end.to raise_error(ActiveRecord::RecordNotUnique, /#{name}/)
      expect(legacy.reload.appointment_automation).to eq(source_key => true)
    end

    it "excludes inactive #{source_key} targets and keeps uniqueness account-scoped" do
      update_indexes
      target = create(:crm_pipeline, account: account)
      inactive = create(:crm_pipeline, account: account, active: false)
      another_account = create(:crm_pipeline)
      config = { 'auto_create_deals' => true, source_key => true }
      set_config(target, config)

      expect { set_config(inactive, config) }.not_to raise_error
      expect { set_config(another_account, config) }.not_to raise_error
    end
  end

  it 'leaves valid corrected indexes unchanged on repeated runs' do
    update_indexes
    snapshot = described_class::INDEXES.keys.to_h { |name| [name, index_state(name)] }
    allow(connection).to receive(:add_index).and_call_original
    allow(connection).to receive(:remove_index).and_call_original

    expect(connection).not_to receive(:add_index)
    expect(connection).not_to receive(:remove_index)
    2.times { update_indexes }

    expect(described_class::INDEXES.keys.to_h { |name| [name, index_state(name)] }).to eq(snapshot)
  end

  it 'recovers an invalid replacement left by an interrupted concurrent build' do
    name, source_key = described_class::INDEXES.first
    replacement = "#{name}_with_master"
    connection.add_index :crm_pipelines, :account_id, name: replacement, unique: true,
                                                   where: migration.send(:predicate, source_key)
    connection.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = #{connection.quote(replacement)}::regclass")

    update_indexes

    expect(index_state(name)).to include('indisvalid' => true)
    expect(index_state(name)['predicate']).to include('auto_create_deals')
    expect(index_state(replacement)).to be_nil
  end

  it 'keeps the legacy index until a replacement build succeeds' do
    name = described_class::INDEXES.keys.first
    original_index = index_state(name)
    allow(connection).to receive(:add_index).and_raise(ActiveRecord::StatementInvalid, 'Build interrupted')

    expect { update_indexes }.to raise_error(ActiveRecord::StatementInvalid, 'Build interrupted')
    expect(index_state(name)).to eq(original_index)
  end

  [
    [:account_id, false, "active AND appointment_automation ->> 'auto_create_from_calendar' = 'true'"],
    [:id, true, "active AND appointment_automation ->> 'auto_create_from_calendar' = 'true'"],
    [:account_id, true, 'active']
  ].each do |columns, unique, predicate|
    it "rejects an unexpected existing definition (#{columns}, unique=#{unique}, #{predicate}) before building or removing indexes" do
      name = described_class::INDEXES.keys.first
      connection.remove_index :crm_pipelines, name: name
      connection.add_index :crm_pipelines, columns, name: name, unique: unique, where: predicate
      original = index_state(name)
      expect(connection).not_to receive(:add_index)
      expect(connection).not_to receive(:remove_index)

      expect { update_indexes }.to raise_error(ActiveRecord::MigrationError, /Unexpected index definition/)

      expect(index_state(name)).to eq(original)
      expect(index_state("#{name}_with_master")).to be_nil
    end
  end

  it 'refuses to remove the legacy index when the replacement is absent or still invalid' do
    name, source_key = described_class::INDEXES.first
    replacement = "#{name}_with_master"
    original = index_state(name)
    expect do
      migration.send(:remove_replaced_index, name, replacement, source_key)
    end.to raise_error(ActiveRecord::MigrationError, /Valid replacement missing/)
    connection.add_index :crm_pipelines, :account_id, name: replacement, unique: true, where: migration.send(:predicate, source_key)
    connection.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = #{connection.quote(replacement)}::regclass")
    expect(connection).not_to receive(:remove_index)

    expect do
      migration.send(:remove_replaced_index, name, replacement, source_key)
    end.to raise_error(ActiveRecord::MigrationError, /Valid replacement missing/)
    expect(index_state(name)).to eq(original)
  end

  it 'resumes a swap interrupted after removing the old index without rebuilding the valid replacement' do
    name, source_key = described_class::INDEXES.first
    replacement = "#{name}_with_master"
    connection.add_index :crm_pipelines, :account_id, name: replacement, unique: true, where: migration.send(:predicate, source_key)
    replacement_oid = index_state(replacement)['indexrelid']
    connection.remove_index :crm_pipelines, name: name

    update_indexes

    expect(index_state(name)).to include('indexrelid' => replacement_oid, 'indisvalid' => true)
    expect(index_state(replacement)).to be_nil
    expect { update_indexes }.not_to(change { index_state(name) })
  end

  it 'retains the legacy index when an unexpected replacement definition is found' do
    name, source_key = described_class::INDEXES.first
    replacement = "#{name}_with_master"
    connection.add_index :crm_pipelines, :account_id, name: replacement, unique: true,
                                                   where: "active AND appointment_automation ->> '#{source_key}' = 'true'"
    original = index_state(name)
    expect(connection).not_to receive(:remove_index)

    expect { update_indexes }.to raise_error(ActiveRecord::MigrationError, /Unexpected replacement index definition/)

    expect(index_state(name)).to eq(original)
  end

  it 'does not restore a predicate that would require deleting retained source flags' do
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end

# No transactional adapter or SQL rewriting in this example: the actual
# PostgreSQL concurrent repair must succeed outside a transaction block.
RSpec.describe UpdateCrmAppointmentTargetIndexes, 'native concurrent repair' do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:source_key) { described_class::INDEXES.values.first }
  let(:name) { described_class::INDEXES.keys.first }
  let(:replacement) { "#{name}_with_master" }

  before { connection.remove_index :crm_pipelines, name: replacement, algorithm: :concurrently, if_exists: true }
  after { connection.remove_index :crm_pipelines, name: replacement, algorithm: :concurrently, if_exists: true }

  it 'repairs an invalid replacement with REINDEX CONCURRENTLY and retains the existing target index' do
    original = connection.select_value("SELECT pg_get_indexdef(to_regclass(#{connection.quote(name)}))")
    connection.add_index :crm_pipelines, :account_id, name: replacement, unique: true,
                                                   where: migration.send(:predicate, source_key), algorithm: :concurrently
    connection.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = #{connection.quote(replacement)}::regclass")

    ActiveRecord::Migration.suppress_messages do
      migration.send(:without_statement_timeout) { migration.send(:prepare_replacement, replacement, source_key) }
    end

    expect(connection.select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = #{connection.quote(replacement)}::regclass")).to be true
    expect(connection.select_value("SELECT pg_get_indexdef(to_regclass(#{connection.quote(name)}))")).to eq(original)
  end
end
