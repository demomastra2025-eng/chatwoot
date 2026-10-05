require 'rails_helper'
require Rails.root.join('db/migrate/20261005190100_ensure_message_content_trigram_index')

# CREATE INDEX CONCURRENTLY cannot run inside a transaction, so these examples run the real migration on the real test
# database outside the transactional wrapper (nothing is mocked or rewritten on the way) and leave the index built.
RSpec.describe EnsureMessageContentTrigramIndex do
  self.use_transactional_tests = false

  let(:db) { ActiveRecord::Base.connection }
  let(:name) { described_class::INDEX_NAME }

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  def index_row
    db.select_one(<<~SQL.squish)
      SELECT pg_class.oid AS oid, pg_index.indisvalid AS valid, pg_get_indexdef(pg_index.indexrelid) AS definition
      FROM pg_index JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname = #{db.quote(name)}
    SQL
  end

  after(:all) { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

  it 'is the index the schema has, a trigram index on the text of the messages' do
    migrate

    expect(index_row['definition']).to include('USING gin (content gin_trgm_ops)')
    expect(Rails.root.join('db/schema.rb').read).to include('name: "index_messages_on_content", opclass: :gin_trgm_ops, using: :gin')
  end

  it 'changes nothing when a valid index is there' do
    migrate
    before = index_row

    migrate

    expect(index_row).to eq(before)
  end

  it 'builds the index when it is missing' do
    db.execute("DROP INDEX IF EXISTS #{name}")

    migrate

    expect(index_row).to include('valid' => true)
  end

  it 'builds an index that an interrupted concurrent build left INVALID instead of accepting it' do
    migrate
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = '#{name}'::regclass")
    expect(index_row['valid']).to be(false)

    migrate

    expect(index_row['valid']).to be(true)
  end

  it 'lifts the statement timeout, bounds the lock wait and puts both back to what the session had' do
    original = [db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')]
    db.execute("SET statement_timeout = '14s'")
    db.execute("SET lock_timeout = '3s'")
    db.execute("DROP INDEX IF EXISTS #{name}")
    seen = []
    allow(db).to receive(:execute).and_wrap_original do |wrapped, sql, *rest, **options|
      seen << [db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')] if sql.to_s.start_with?('CREATE INDEX')
      wrapped.call(sql, *rest, **options)
    end

    migrate

    expect(seen.uniq).to eq([%w[1h 5s]]) # PostgreSQL shows 60min as 1h
    expect([db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')]).to eq(%w[14s 3s])
  ensure
    db.execute("SET statement_timeout = '#{original[0]}'")
    db.execute("SET lock_timeout = '#{original[1]}'")
  end

  context 'when messages is locked by a long transaction' do
    let(:holder) { ActiveRecord::Base.connection_pool.checkout }

    before do
      db.execute("DROP INDEX IF EXISTS #{name}")
      stub_const("#{described_class}::LOCK_TIMEOUT", '100ms')
      stub_const("#{described_class}::ATTEMPTS", 3)
      stub_const("#{described_class}::RETRY_PAUSE", 0)
      holder.execute('BEGIN')
      holder.execute('LOCK TABLE messages IN SHARE ROW EXCLUSIVE MODE')
    end

    after do
      holder.execute('ROLLBACK')
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    it 'gives up after the bounded number of attempts instead of waiting behind it' do
      pauses = []
      allow_any_instance_of(described_class).to receive(:sleep) { |_migration, seconds| pauses << seconds } # rubocop:disable RSpec/AnyInstance

      expect { migrate }.to raise_error(ActiveRecord::LockWaitTimeout)

      expect(pauses.size).to eq(described_class::ATTEMPTS - 1)
    end

    it 'builds the index on a later attempt once the lock is gone' do
      allow_any_instance_of(described_class).to receive(:sleep) { holder.execute('ROLLBACK') } # rubocop:disable RSpec/AnyInstance

      migrate

      expect(index_row).to include('valid' => true)
    end
  end

  it 'leaves the index in place on rollback' do
    migrate

    ActiveRecord::Migration.suppress_messages { described_class.new.down }

    expect(index_row).to include('valid' => true)
  end
end
