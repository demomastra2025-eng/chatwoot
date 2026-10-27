class AddNamePartsTrigramIndexToContacts < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_contacts_on_name_parts_trgm'.freeze
  BUILD_STATEMENT_TIMEOUT = '30min'.freeze
  LOCK_TIMEOUT = '5s'.freeze
  ATTEMPTS = 5
  RETRY_PAUSE = 10

  def up
    with_build_timeouts do
      with_retries do
        drop_invalid_index!
        execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS #{INDEX_NAME} ON contacts USING gin (last_name gin_trgm_ops, middle_name gin_trgm_ops)")
      end
      with_retries { execute('ANALYZE contacts') }
    end
  end

  def down
    with_build_timeouts { with_retries { execute("DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}") } }
  end

  private

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
