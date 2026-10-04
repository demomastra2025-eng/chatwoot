require 'rails_helper'

RSpec.describe HairTrigger do
  it 'uses the current migration pool and parses trigger declarations from migration files' do
    migration_pool = ActiveRecord::Tasks::DatabaseTasks.migration_connection_pool
    expect(ActiveRecord::Tasks::DatabaseTasks).to receive(:migration_connection_pool).at_least(:once).and_call_original
    expect(migration_pool).to receive(:migration_context).at_least(:once).and_call_original

    migrator = described_class.migrator
    expect(migrator).to be_a(ActiveRecord::Migrator)
    expect(migrator.migrated).to be_a(Set)

    allow(described_class::MigrationReader).to receive(:get_triggers).and_call_original
    expect(described_class::MigrationReader).to receive(:get_triggers).at_least(:once).and_call_original
    described_class.current_migrations(in_rake_task: true)

    expect(extract_fixture_trigger_tables).to eq(['accounts'])
  end

  it 'dumps real trigger definitions when HairTrigger passes a connection adapter' do
    output = StringIO.new

    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, output)

    expect(output.string).to include('accounts_after_insert_row_tr')
  end

  def extract_fixture_trigger_tables
    Tempfile.create(['crm-hairtrigger-reader', '.rb']) do |migration_file|
      migration_file.write(<<~RUBY)
        class CrmHairTriggerReaderFixture < ActiveRecord::Migration[7.2]
          def up
            create_trigger(:crm_hairtrigger_reader).on(:accounts).before(:insert) { 'RETURN NEW' }
          end
        end
      RUBY
      migration_file.flush
      migration = Struct.new(:filename, :name).new(migration_file.path, 'CrmHairTriggerReaderFixture')
      triggers = described_class::MigrationReader.get_triggers(migration, include_manual_triggers: true)
      triggers.map { |trigger| trigger.options[:table] }
    end
  end
end
