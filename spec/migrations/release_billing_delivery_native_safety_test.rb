# rubocop:disable RSpec/SpecFilePathSuffix -- Standalone PG test; no Rails schema loader or global cleanup.
require 'rspec/autorun'
require 'active_record'
require 'active_support/all'
require 'timeout'

database = ENV.fetch('POSTGRES_TEST_DATABASE')
raise 'Use an explicitly isolated test database' unless ENV['RAILS_ENV'] == 'test' && database.end_with?('_test')

ActiveRecord::Base.establish_connection(
  adapter: 'postgresql', host: ENV.fetch('POSTGRES_HOST', '127.0.0.1'), port: ENV.fetch('POSTGRES_PORT', '55996'),
  database: database, username: ENV.fetch('POSTGRES_USERNAME', 'postgres'), password: ENV.fetch('POSTGRES_PASSWORD', nil), pool: 4
)
require File.expand_path('../../db/migrate/20261101183000_create_billing_autobilling_tables', __dir__)
require File.expand_path('../../db/migrate/20261102003500_add_wa_historical_delivery_index_to_messages', __dir__)

RSpec.describe ActiveRecord::Migration do
  let(:connection) { ActiveRecord::Base.connection }
  let(:schema) { "release_safety_#{SecureRandom.hex(5)}" }
  let(:index_name) { AddWaHistoricalDeliveryIndexToMessages::INDEX_NAME }

  around do |example|
    previous_schema = connection.schema_search_path
    previous_lock = connection.select_value('SHOW lock_timeout')
    previous_statement = connection.select_value('SHOW statement_timeout')
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = "#{schema},public"
    connection.execute("SET lock_timeout = '9s'")
    connection.execute("SET statement_timeout = '8s'")
    described_class.suppress_messages { example.run }
  ensure
    connection.execute("SET lock_timeout = #{connection.quote(previous_lock)}")
    connection.execute("SET statement_timeout = #{connection.quote(previous_statement)}")
    connection.schema_search_path = previous_schema
    connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    connection.schema_cache.clear!
  end

  def create_billing
    connection.create_table(:accounts, id: :integer)
    connection.transaction(requires_new: true) { CreateBillingAutobillingTables.new.up }
  end

  def create_messages(table = :messages)
    connection.create_table(table) do |t|
      t.bigint :account_id
      t.bigint :inbox_id
      t.datetime :created_at
      t.datetime :updated_at
      t.integer :message_type
      t.integer :status
      t.boolean :private
      t.text :source_id
    end
  end

  def with_blocker(table, write: false)
    ready = Queue.new
    release = Queue.new
    relation = connection.quote_table_name("#{schema}.#{table}")
    worker = start_blocker(relation, ready, release, write)
    failure = Timeout.timeout(10) { ready.pop }
    raise failure if failure

    yield
  ensure
    release << true
    raise 'blocker did not release' unless worker.join(10)
  end

  def start_blocker(relation, ready, release, write)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |blocker|
        blocker.transaction do
          blocker.execute(write ? "INSERT INTO #{relation} (id) VALUES (90001)" : "LOCK TABLE #{relation} IN ACCESS EXCLUSIVE MODE")
          ready << nil
          release.pop
          raise ActiveRecord::Rollback
        end
      end
    rescue StandardError => e
      ready << e
    end
  end

  it 'creates all four validated billing FKs with the original deletion actions and column defaults' do
    create_billing
    expected = {
      billing_account_profiles: [['accounts', 'account_id', nil]],
      billing_invoices: [['accounts', 'account_id', nil]],
      billing_payment_events: [['accounts', 'account_id', :nullify], ['billing_invoices', 'billing_invoice_id', :nullify]]
    }
    expected.each do |table, keys|
      actual = connection.foreign_keys(table)
      expect(actual.map { |key| [key.to_table, key.column, key.on_delete] }).to match_array(keys)
      expect(actual.all?(&:validate?)).to be(true)
    end
    expect(connection.columns(:billing_account_profiles).find { |c| c.name == 'billing_enabled' }.default).to eq('false')
    expect(connection.columns(:billing_account_profiles).find { |c| c.name == 'autopay_enabled' }.default).to eq('false')
    connection.execute('INSERT INTO accounts (id) VALUES (41)')
    expect do
      connection.execute('INSERT INTO billing_account_profiles (account_id, created_at, updated_at) VALUES (999, NOW(), NOW())')
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
    expect(connection.select_value('SHOW statement_timeout')).to eq('8s')
  end

  it 'rolls back all billing creation on a native parent lock timeout' do
    connection.create_table(:accounts, id: :integer)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_blocker(:accounts) do
      expect do
        connection.transaction(requires_new: true) { CreateBillingAutobillingTables.new.up }
      end.to raise_error(ActiveRecord::LockWaitTimeout) { |e| expect(e.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)).to eq('55P03') }
    end
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(3.5, 6)
    expect(connection.select_values('SELECT tablename FROM pg_tables WHERE schemaname=current_schema()')).to eq(['accounts'])
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
  end

  it 'preserves billing rows and the delivery index when application code is rolled back' do
    create_billing
    connection.execute('INSERT INTO accounts (id) VALUES (41)')
    connection.execute('INSERT INTO billing_account_profiles (account_id, created_at, updated_at) VALUES (41, NOW(), NOW())')
    create_messages
    AddWaHistoricalDeliveryIndexToMessages.new.up
    expect { CreateBillingAutobillingTables.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect { AddWaHistoricalDeliveryIndexToMessages.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(connection.select_value('SELECT account_id FROM billing_account_profiles')).to eq(41)
    expect(connection.index_exists?(:messages, name: index_name)).to be(true)
  end

  it 'creates a valid concurrent delivery index and keeps its OID on a repeat' do
    create_messages
    migration = AddWaHistoricalDeliveryIndexToMessages.new
    migration.up
    oid = connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")
    migration.up
    expect(connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")).to eq(oid)
    definition = migration.send(:delivery_index_definition)
    expect(definition.values_at('known_shape', 'indisvalid', 'indisready', 'indislive')).to eq([true, true, true, true])
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
  end

  [true, false].each do |valid|
    it "refuses an unknown #{valid ? 'valid' : 'invalid'} index without replacing it" do
      create_messages
      connection.execute("CREATE INDEX #{index_name} ON messages (id)")
      oid = connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")
      connection.execute("UPDATE pg_index SET indisvalid=false WHERE indexrelid=#{oid}") unless valid
      expect { AddWaHistoricalDeliveryIndexToMessages.new.up }.to raise_error(ActiveRecord::MigrationError, /explicit maintenance/)
      expect(connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")).to eq(oid)
      expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
    end
  end

  it 'refuses a same-named index on another table without changing either table' do
    create_messages
    create_messages(:unrelated)
    connection.execute("CREATE INDEX #{index_name} ON unrelated (id)")
    oid = connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")
    expect { AddWaHistoricalDeliveryIndexToMessages.new.up }.to raise_error(ActiveRecord::MigrationError, /explicit maintenance/)
    expect(connection.select_value("SELECT '#{schema}.#{index_name}'::regclass::oid")).to eq(oid)
    expect(connection.indexes(:messages)).to be_empty
  end

  it 'stops on a native delivery table lock timeout and restores session settings' do
    create_messages
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_blocker(:messages) do
      expect { AddWaHistoricalDeliveryIndexToMessages.new.up }.to raise_error(ActiveRecord::LockWaitTimeout)
    end
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(3.5, 6)
    expect(connection.indexes(:messages)).to be_empty
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
  end

  it 'refuses a real interrupted concurrent index instead of marking it successfully applied' do
    create_messages
    migration = AddWaHistoricalDeliveryIndexToMessages.new
    with_blocker(:messages, write: true) do
      connection.execute("SET statement_timeout = '150ms'")
      expect { migration.up }.to raise_error(ActiveRecord::QueryCanceled)
    ensure
      connection.execute("SET statement_timeout = '8s'")
    end
    definition = migration.send(:delivery_index_definition)
    expect(definition['indisvalid']).to be(false)
    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /explicit maintenance/)
    expect(migration.send(:delivery_index_definition)['indisvalid']).to be(false)
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
  end
end
# rubocop:enable RSpec/SpecFilePathSuffix
