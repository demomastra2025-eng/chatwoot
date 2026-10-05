require 'rails_helper'
require Rails.root.join('db/migrate/20261005190000_add_phone_digit_search_indexes_to_contacts')

# CREATE INDEX CONCURRENTLY cannot run inside a transaction, so these examples run the real migration on the real test
# database outside the transactional wrapper (nothing is mocked or rewritten on the way) and leave the indexes built.
RSpec.describe AddPhoneDigitSearchIndexesToContacts do
  self.use_transactional_tests = false

  let(:db) { ActiveRecord::Base.connection }
  let(:names) { described_class::INDEXES.keys }

  def migrate(direction = :up)
    ActiveRecord::Migration.suppress_messages { described_class.new.public_send(direction) }
  end

  def quoted_names
    names.map { |name| db.quote(name) }.join(', ')
  end

  def index_validity
    db.select_rows(<<~SQL.squish).to_h
      SELECT pg_class.relname, pg_index.indisvalid FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname IN (#{quoted_names})
    SQL
  end

  def index_definitions
    db.select_values("SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname IN (#{quoted_names}) ORDER BY indexname")
  end

  before { names.each { |name| db.execute("DROP INDEX IF EXISTS #{name}") } }

  after(:all) { described_class.new.tap { |migration| ActiveRecord::Migration.suppress_messages { migration.up } } }

  it 'builds both indexes concurrently, valid, with the expressions Search::PhoneQuery queries' do
    migrate

    expect(index_validity).to eq(names.index_with { true })
    expect(index_definitions).to contain_exactly(
      a_string_including("USING btree (account_id, \"right\"(regexp_replace((phone_number)::text, '[^0-9]'::text, ''::text, 'g'::text), 10))"),
      a_string_including("USING gin (regexp_replace((phone_number)::text, '[^0-9]'::text, ''::text, 'g'::text) gin_trgm_ops)")
    )
  end

  it 'matches the schema.rb definitions' do
    migrate
    schema = Rails.root.join('db/schema.rb').read

    expect(schema).to include('name: "index_contacts_on_account_id_and_phone_national"')
    expect(schema).to include('name: "index_contacts_on_phone_digits_trgm", using: :gin')
  end

  it 'can be run again without changing anything' do
    migrate
    definitions = index_definitions

    migrate

    expect(index_definitions).to eq(definitions)
    expect(index_validity.values).to all(be(true))
  end

  it 'builds an index that an interrupted concurrent build left INVALID instead of accepting it' do
    migrate
    db.execute("UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = 'index_contacts_on_phone_digits_trgm'::regclass")
    expect(index_validity['index_contacts_on_phone_digits_trgm']).to be(false)

    migrate

    expect(index_validity).to eq(names.index_with { true })
  end

  it 'lifts the statement timeout and bounds the lock wait for the builds, then puts both back to what the session had' do
    original_timeouts = [db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')]
    db.execute("SET statement_timeout = '14s'")
    db.execute("SET lock_timeout = '3s'")
    seen = []
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      seen << [db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')] if sql.to_s.start_with?('CREATE INDEX')
      original.call(sql, *rest, **options)
    end

    migrate

    expect(seen.uniq).to eq([['30min', '5s']])
    expect(db.select_value('SHOW statement_timeout')).to eq('14s')
    expect(db.select_value('SHOW lock_timeout')).to eq('3s')
  ensure
    db.execute("SET statement_timeout = '#{original_timeouts[0]}'")
    db.execute("SET lock_timeout = '#{original_timeouts[1]}'")
  end

  context 'when contacts is locked by a long transaction' do
    let(:holder) { ActiveRecord::Base.connection_pool.checkout }

    before do
      stub_const("#{described_class}::LOCK_TIMEOUT", '100ms')
      stub_const("#{described_class}::ATTEMPTS", 3)
      stub_const("#{described_class}::RETRY_PAUSE", 0)
      holder.execute('BEGIN')
      holder.execute('LOCK TABLE contacts IN SHARE ROW EXCLUSIVE MODE')
    end

    after do
      holder.execute('ROLLBACK')
      ActiveRecord::Base.connection_pool.checkin(holder)
    end

    it 'gives up after the bounded number of attempts instead of waiting behind it, and leaves no broken index' do
      pauses = []
      allow_any_instance_of(described_class).to receive(:sleep) { |_migration, seconds| pauses << seconds } # rubocop:disable RSpec/AnyInstance

      expect { migrate }.to raise_error(ActiveRecord::LockWaitTimeout)

      expect(pauses.size).to eq(described_class::ATTEMPTS - 1)
      expect(index_validity.values).to all(be(true))
    end

    it 'builds the indexes on a later attempt once the lock is gone' do
      allow_any_instance_of(described_class).to receive(:sleep) { holder.execute('ROLLBACK') } # rubocop:disable RSpec/AnyInstance

      migrate

      expect(index_validity).to eq(names.index_with { true })
    end

    it 'restores the timeouts also when it gives up' do
      allow_any_instance_of(described_class).to receive(:sleep) # rubocop:disable RSpec/AnyInstance
      before_values = [db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')]

      expect { migrate }.to raise_error(ActiveRecord::LockWaitTimeout)

      expect([db.select_value('SHOW statement_timeout'), db.select_value('SHOW lock_timeout')]).to eq(before_values)
    end
  end

  it 'is reversible' do
    migrate
    migrate(:down)

    expect(index_validity).to be_empty
  end

  describe 'the plan of a phone search' do
    let(:account) { create(:account) }

    before do
      migrate
      # enough rows for the planner to prefer an exact index lookup to the index on the account
      Contact.insert_all(Array.new(300) { |index| { account_id: account.id, name: "Контакт #{index}", phone_number: "+7701#{1_000_000 + index}" } })
      db.execute('ANALYZE contacts')
    end

    after do
      Contact.where(account_id: account.id).delete_all
      account.destroy
    end

    # The queries repeat the indexed expressions exactly, so PostgreSQL can answer them from the indexes: each arm of a
    # phone search is explained on its own, with sequential scans switched off to make the answer independent of the
    # size of the test table (the planner measurements on a table of 150,000 contacts are in the commit notes).
    def plan_of(relation)
      plan = nil
      ActiveRecord::Base.transaction do
        db.execute('SET LOCAL enable_seqscan = off')
        plan = relation.explain.inspect
      end
      plan
    end

    it 'answers the last-10-digits arm from the (account_id, right 10 digits) index' do
      query = Search::PhoneQuery.parse('8 707 281 70 60')

      expect(plan_of(account.contacts.where(query.national_condition))).to include('index_contacts_on_account_id_and_phone_national')
    end

    it 'answers the contained-digits arms from the trigram index on the digits, whatever the length typed' do
      aggregate_failures do
        ['2817060', '7072', '+7 (707) 281-70-6', '87072817060'].each do |text|
          arms = Search::PhoneQuery.parse(text).fragment_conditions

          expect(plan_of(Contact.where(arms.reduce { |combined, arm| combined.or(arm) }))).to include('index_contacts_on_phone_digits_trgm'),
                                                                                                "expected #{text.inspect} to use the trigram index"
        end
      end
    end
  end
end
