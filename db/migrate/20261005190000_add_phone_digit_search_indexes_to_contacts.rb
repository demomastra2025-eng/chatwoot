class AddPhoneDigitSearchIndexesToContacts < ActiveRecord::Migration[7.1]
  # Expand step only: two expression indexes on contacts, both built CONCURRENTLY (readers and writers are not blocked).
  # They serve Search::PhoneQuery, which finds a number typed in any format (8707..., +7 707 ..., 7 (707) ...) by digits:
  #   - (account_id, right 10 digits): the national number of a complete number, an exact match;
  #   - a trigram index on all digits: a number or a fragment of 4-15 digits inside the stored number.
  # The queries have to use these exact expressions, see Search::PhoneQuery.
  #
  # Safe to run again after an interruption: an interrupted concurrent build leaves an INVALID index under the name,
  # which IF NOT EXISTS alone would accept for good, so it is dropped and built again (a valid one is left alone).
  # The builds lift the request statement timeout (14s by default, config/database.yml) and wait for locks only for a
  # short time: when the table is busy the attempt is cancelled and repeated a few times, so that the migration never
  # queues behind a long transaction and blocks the writers that queue behind it. Both settings are put back to what the
  # session had before, not to the server default.
  #
  # A new expression index has NO statistics until the table is analysed, and without them the planner assumes that a
  # number matches 0.5% of the table: for a complete number it then walks the contacts of the account in order and
  # stops at the LIMIT instead of using the indexes (measured on 56,000 contacts of one account: 407 ms instead of
  # 3 ms). So the table is analysed (a sample of 30,000 rows, no table rewrite, SHARE UPDATE EXCLUSIVE only) as the last
  # step of #up, and the statistics exist from the first search after the deploy, not after the next autovacuum.
  disable_ddl_transaction!

  DIGITS = "regexp_replace(phone_number, '[^0-9]'::text, ''::text, 'g'::text)".freeze
  INDEXES = {
    'index_contacts_on_account_id_and_phone_national' => "USING btree (account_id, right(#{DIGITS}, 10))",
    'index_contacts_on_phone_digits_trgm' => "USING gin (#{DIGITS} gin_trgm_ops)"
  }.freeze
  BUILD_STATEMENT_TIMEOUT = '30min'.freeze
  LOCK_TIMEOUT = '5s'.freeze
  ATTEMPTS = 5
  RETRY_PAUSE = 10 # seconds

  def up
    with_build_timeouts do
      INDEXES.each { |name, definition| build_index(name, definition) }
      with_retries { execute('ANALYZE contacts') }
    end
  end

  def down
    with_build_timeouts do
      INDEXES.each_key { |name| with_retries { execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}") } }
    end
  end

  private

  def build_index(name, definition)
    with_retries do
      drop_invalid_index!(name)
      execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} ON contacts #{definition}")
    end
  end

  def with_retries
    attempts = 0
    begin
      attempts += 1
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if attempts >= ATTEMPTS

      say("contacts is busy, attempt #{attempts} of #{ATTEMPTS} cancelled; trying again in #{RETRY_PAUSE}s")
      sleep(RETRY_PAUSE)
      retry
    end
  end

  def drop_invalid_index!(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(name)} AND pg_namespace.nspname = current_schema() AND NOT pg_index.indisvalid
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}") if invalid.present?
  end

  def with_build_timeouts
    previous_statement_timeout = select_value('SHOW statement_timeout')
    previous_lock_timeout = select_value('SHOW lock_timeout')
    execute("SET statement_timeout = '#{BUILD_STATEMENT_TIMEOUT}'")
    execute("SET lock_timeout = '#{LOCK_TIMEOUT}'")
    yield
  ensure
    execute("SET statement_timeout = #{quote(previous_statement_timeout)}") if previous_statement_timeout
    execute("SET lock_timeout = #{quote(previous_lock_timeout)}") if previous_lock_timeout
  end
end
