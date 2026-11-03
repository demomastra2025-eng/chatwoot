# rubocop:disable RSpec/SpecFilePathSuffix -- Intentionally standalone; excluded from the Rails full-schema suite.
# Standalone contract test: bundle exec ruby spec/migrations/ai_expand_native_safety_test.rb
# Avoid Rails' global committed-row truncator and automatic full-schema loading.
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

%w[
  20261102013000_create_account_ai_usage_events
  20261102013100_add_pending_ai_usage_index_to_messages
  20261102013200_create_captain_reply_suggestion_identities
  20261102093000_manage_organization_billing_foundation
  20261102103000_create_billing_unit_ledger
  20261103010000_create_captain_shadow_training
].each { |migration| require File.expand_path("../../db/migrate/#{migration}", __dir__) }

RSpec.describe ActiveRecord::Migration do
  # Concurrent index creation and the second lock-holder session require commits.
  # Every example owns a disposable schema; no global tables are truncated.

  let(:schema) { "ai_expand_spec_#{SecureRandom.hex(5)}" }
  let(:connection) { ActiveRecord::Base.connection }

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

  def with_blocker(table, insert: false)
    ready = Queue.new
    release = Queue.new
    relation = connection.quote_table_name("#{schema}.#{table}")
    worker = start_blocker(relation, ready, release, insert)
    error = Timeout.timeout(10) { ready.pop }
    raise error if error

    yield
  ensure
    release << true
    raise 'lock holder did not release' unless worker.join(10)
  end

  def start_blocker(relation, ready, release, insert)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |blocker|
        blocker.transaction do
          if insert
            blocker.execute("INSERT INTO #{relation} (ai_usage_pending) VALUES (true)")
          else
            blocker.execute("LOCK TABLE #{relation} IN ACCESS EXCLUSIVE MODE")
          end
          ready << nil
          release.pop
          raise ActiveRecord::Rollback
        end
      end
    rescue StandardError => e
      ready << e
    end
  end

  {
    CreateAccountAiUsageEvents => %i[accounts contacts messages],
    CreateCaptainReplySuggestionIdentities => %i[accounts conversations users],
    ManageOrganizationBillingFoundation => %i[accounts organizations],
    CreateBillingUnitLedger => %i[accounts billing_accounts billing_subscriptions],
    CreateCaptainShadowTraining => %i[accounts conversations captain_assistants users messages]
  }.each do |migration_class, parents|
    it "rolls back #{migration_class} on a native parent lock timeout within its 5s budget" do
      parents.each { |table| connection.create_table(table) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      failure = nil
      with_blocker(:accounts) do
        connection.transaction(requires_new: true) { migration_class.new.up }
      rescue ActiveRecord::LockWaitTimeout => e
        failure = e
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(failure).to be_a(ActiveRecord::LockWaitTimeout)
      expect(failure.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)).to eq('55P03')
      expect(elapsed).to be_between(3.5, 6.0)
      local = connection.select_values('SELECT tablename FROM pg_tables WHERE schemaname=current_schema()')
      expect(local).to match_array(parents.map(&:to_s))
      expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
      expect(connection.select_value('SHOW statement_timeout')).to eq('8s')
      expect(connection.column_exists?(:messages, :ai_usage_pending)).to be(false) if parents.include?(:messages)
    end
  end

  def create_messages
    connection.create_table(:messages) do |table|
      table.datetime :ai_usage_retry_at
      table.boolean :ai_usage_pending, null: false, default: false
    end
  end

  def index_definition
    AddPendingAiUsageIndexToMessages.new.send(:pending_index_definition)
  end

  it 'repairs an actual failed concurrent build of the exact known index and is idempotent' do
    create_messages
    migration = AddPendingAiUsageIndexToMessages.new
    with_blocker(:messages, insert: true) do
      connection.execute("SET statement_timeout = '150ms'")
      expect { migration.up }.to raise_error(ActiveRecord::QueryCanceled)
      expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
    ensure
      connection.execute("SET statement_timeout = '8s'")
    end
    expect(index_definition.fetch('indisvalid')).to be(false)

    migration.up
    first_oid = connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")
    migration.up
    expect(connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")).to eq(first_oid)
    expect(index_definition.values_at('known_shape', 'indisvalid', 'indisready', 'indislive')).to eq([true, true, true, true])
    expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
  end

  validity_states = [true, false].freeze
  {
    'wrong ordered keys' => '(id,ai_usage_retry_at) WHERE ai_usage_pending=true',
    'wrong predicate' => '(ai_usage_retry_at,id) WHERE ai_usage_pending=false',
    'included column' => '(ai_usage_retry_at,id) INCLUDE (ai_usage_pending) WHERE ai_usage_pending=true',
    'descending key' => '(ai_usage_retry_at DESC,id) WHERE ai_usage_pending=true',
    'expression key' => "((ai_usage_retry_at + interval '1 second'),id) WHERE ai_usage_pending=true"
  }.each do |label, definition|
    validity_states.each do |valid|
      it "refuses an unknown #{valid ? 'valid' : 'invalid'} index with #{label} without dropping it" do
        create_messages
        connection.execute("CREATE INDEX idx_messages_pending_ai_usage ON messages #{definition}")
        oid = connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")
        connection.execute("UPDATE pg_index SET indisvalid=false WHERE indexrelid=#{oid}") unless valid

        expect { AddPendingAiUsageIndexToMessages.new.up }.to raise_error(ActiveRecord::MigrationError, /unknown pending AI usage index shape/)
        expect(connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")).to eq(oid)
        expect(connection.select_value('SHOW lock_timeout')).to eq('9s')
      end
    end
  end

  it 'refuses an index on a different table with the protected name' do
    create_messages
    connection.create_table(:unrelated) do |table|
      table.datetime :ai_usage_retry_at
      table.boolean :ai_usage_pending
    end
    connection.execute('CREATE INDEX idx_messages_pending_ai_usage ON unrelated (ai_usage_retry_at,id) WHERE ai_usage_pending=true')
    oid = connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")

    expect { AddPendingAiUsageIndexToMessages.new.up }.to raise_error(ActiveRecord::MigrationError, /unknown pending AI usage index shape/)
    expect(connection.select_value("SELECT '#{schema}.idx_messages_pending_ai_usage'::regclass::oid")).to eq(oid)
  end

  def create_legacy_foundation
    connection.create_table(:accounts, id: :integer)
    connection.create_table(:organizations)
    load File.expand_path('../fixtures/billing/legacy_foundation_schema.rb', __dir__)
  end

  it 'refuses pg_temp shadowing before altering the permanent foundation' do
    create_legacy_foundation
    connection.execute('CREATE TEMP TABLE billing_accounts (id bigint)')

    expect do
      connection.transaction(requires_new: true) { ManageOrganizationBillingFoundation.new.up }
    end.to raise_error(ActiveRecord::MigrationError, /relation changed or shadowed/)
    expect(connection.column_exists?("#{schema}.billing_accounts", :foundation_state)).to be(false)
  ensure
    connection.execute('DROP TABLE IF EXISTS pg_temp.billing_accounts')
  end

  it 'rejects a temporary shadow even when all local foundation tables are absent' do
    connection.create_table(:accounts, id: :integer)
    connection.create_table(:organizations)
    connection.execute('CREATE TEMP TABLE billing_accounts (id bigint)')

    expect do
      connection.transaction(requires_new: true) { ManageOrganizationBillingFoundation.new.up }
    end.to raise_error(ActiveRecord::MigrationError, /relation changed or shadowed/)
    local = connection.select_values("SELECT tablename FROM pg_tables WHERE schemaname=current_schema() AND tablename LIKE 'billing_%'")
    expect(local).to be_empty
  ensure
    connection.execute('DROP TABLE IF EXISTS pg_temp.billing_accounts')
  end

  it 'creates a fresh local foundation when unrelated permanent names exist in a fallback schema' do
    connection.create_table(:accounts, id: :integer)
    connection.create_table(:organizations)
    fallback = "#{schema}_fallback"
    connection.execute("CREATE SCHEMA #{fallback}")
    ManageOrganizationBillingFoundation::TABLES.each do |table|
      relation = connection.quote_table_name("#{fallback}.#{table}")
      connection.execute("CREATE TABLE #{relation} (unrelated integer)")
    end
    connection.schema_search_path = "#{schema},#{fallback},public"

    connection.transaction(requires_new: true) { ManageOrganizationBillingFoundation.new.up }

    expect(connection.column_exists?("#{schema}.billing_accounts", :foundation_state)).to be(true)
    expect(connection.column_exists?("#{fallback}.billing_accounts", :foundation_state)).to be(false)
    expect(connection.columns("#{fallback}.billing_accounts").map(&:name)).to eq(['unrelated'])
  ensure
    connection.schema_search_path = "#{schema},public"
    connection.execute("DROP SCHEMA IF EXISTS #{fallback} CASCADE") if fallback
  end

  it 'uses ONLY parent locks and refuses a descendant attached after the topology precheck' do
    create_legacy_foundation
    migration = ManageOrganizationBillingFoundation.new
    ready = Queue.new
    release = Queue.new
    worker = nil
    parent = connection.quote_table_name("#{schema}.billing_accounts")
    child = connection.quote_table_name("#{schema}.synthetic_descendant")
    allow(migration).to receive(:validate_legacy_relations!).and_wrap_original do |original|
      result = original.call
      unless worker
        worker = start_inherited_child_blocker(parent, child, ready, release)
        error = Timeout.timeout(10) { ready.pop }
        raise error if error
      end
      result
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect do
      connection.transaction(requires_new: true) { migration.up }
    end.to raise_error(ActiveRecord::MigrationError, /non-ordinary billing foundation/)
    # Recursive LOCK would wait for the child's AX lock and raise 55P03 at 4s.
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3.5
    expect(connection.column_exists?("#{schema}.billing_accounts", :foundation_state)).to be(false)
  ensure
    release << true
    raise 'child lock holder did not release' if worker && !worker.join(10)
  end

  def start_inherited_child_blocker(parent, child, ready, release)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |blocker|
        blocker.execute("CREATE TABLE #{child} () INHERITS (#{parent})")
        blocker.transaction do
          blocker.execute("LOCK TABLE ONLY #{child} IN ACCESS EXCLUSIVE MODE")
          ready << nil
          release.pop
          raise ActiveRecord::Rollback
        end
      end
    rescue StandardError => e
      ready << e
    end
  end

  it 'retains all six migration histories on rollback before issuing any DDL' do
    classes = [CreateAccountAiUsageEvents, AddPendingAiUsageIndexToMessages, CreateCaptainReplySuggestionIdentities,
               ManageOrganizationBillingFoundation, CreateBillingUnitLedger, CreateCaptainShadowTraining]
    classes.each do |migration_class|
      migration = migration_class.new
      expect(migration).not_to receive(:execute)
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end

# rubocop:enable RSpec/SpecFilePathSuffix
