class EnsureMessageContentTrigramIndex < ActiveRecord::Migration[7.1]
  # The literal search of message text (Search::MessageQuery) is answered from the pg_trgm index on messages.content,
  # index_messages_on_content, which db/migrate/20230426130150_init_schema.rb created and every installation has had since.
  # This step builds it only when it is missing or INVALID (an interrupted concurrent build leaves an INVALID index under
  # the name, which IF NOT EXISTS alone would accept for good), so on a database that has a valid one it changes nothing
  # and takes milliseconds. Built CONCURRENTLY (readers and writers are not blocked), without the request statement
  # timeout, waiting for locks only for a short time and retrying a few times, like
  # 20261005190000_add_phone_digit_search_indexes_to_contacts.rb; both settings are put back to what the session had.
  disable_ddl_transaction!

  INDEX_NAME = 'index_messages_on_content'.freeze
  BUILD_STATEMENT_TIMEOUT = '60min'.freeze
  LOCK_TIMEOUT = '5s'.freeze
  ATTEMPTS = 5
  RETRY_PAUSE = 10 # seconds

  def up
    with_build_timeouts do
      with_retries do
        drop_invalid_index!
        execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS #{INDEX_NAME} ON messages USING gin (content gin_trgm_ops)")
      end
    end
  end

  # The index predates this migration and the search needs it, so rolling back leaves it in place.
  def down; end

  private

  def with_retries
    attempts = 0
    begin
      attempts += 1
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if attempts >= ATTEMPTS

      say("messages is busy, attempt #{attempts} of #{ATTEMPTS} cancelled; trying again in #{RETRY_PAUSE}s")
      sleep(RETRY_PAUSE)
      retry
    end
  end

  def drop_invalid_index!
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(INDEX_NAME)} AND pg_namespace.nspname = current_schema() AND NOT pg_index.indisvalid
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}") if invalid.present?
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
