class MakeTranscriptionSearchIndexLegacyJsonSafe < ActiveRecord::Migration[7.1]
  # The previously published message expression cast every serialized JSON string directly to json. Imported legacy
  # values can be JSON strings whose contents are not JSON, which made writes fail while the GIN index was present.
  # Drop only that message index before rebuilding it so writes become safe immediately; exact search has a bounded
  # fallback while the concurrent index build is in progress. The attachment index is unaffected.
  disable_ddl_transaction!

  NORMALIZED_ATTRIBUTES = <<~'SQL'.squish.freeze
    (CASE json_typeof(content_attributes)
     WHEN 'object' THEN content_attributes
     WHEN 'string' THEN CASE
       WHEN (content_attributes #>> '{}') IS JSON OBJECT
         THEN (content_attributes #>> '{}')::json
       ELSE '{}'::json
     END
     ELSE '{}'::json END)
  SQL
  MESSAGE_SEARCH_TEXT = [
    "COALESCE(processed_message_content, ''::text)",
    "COALESCE(#{NORMALIZED_ATTRIBUTES} ->> 'text', ''::text)",
    "COALESCE(#{NORMALIZED_ATTRIBUTES} ->> 'text_content', ''::text)",
    "COALESCE(#{NORMALIZED_ATTRIBUTES} ->> 'transcribed_text', ''::text)",
    "COALESCE(#{NORMALIZED_ATTRIBUTES} -> 'email' ->> 'subject', ''::text)",
    "COALESCE(#{NORMALIZED_ATTRIBUTES} -> 'email' ->> 'text_content', ''::text)"
  ].join(" || E'\\n' || ").freeze
  MESSAGE_INDEX_NAME = 'index_messages_on_transcription_search_text'.freeze
  MESSAGE_INDEX_EXPRESSION = "(#{MESSAGE_SEARCH_TEXT}) gin_trgm_ops".freeze
  SAFE_INDEX_DEFINITION_FRAGMENTS = [
    'USING gin', 'gin_trgm_ops', 'processed_message_content', "->> 'text'::text", "->> 'text_content'::text",
    "->> 'transcribed_text'::text", "-> 'email'::text", "->> 'subject'::text", 'IS JSON OBJECT'
  ].freeze

  BUILD_STATEMENT_TIMEOUT = '30min'.freeze
  LOCK_TIMEOUT = '5s'.freeze
  ATTEMPTS = 5
  RETRY_PAUSE = 10 # seconds

  def up
    with_build_timeouts do
      ensure_safe_message_index
      # Refresh planner statistics even on a valid-index retry after a previous run was interrupted after CREATE INDEX.
      with_retries { execute("ANALYZE #{quote_table_name(:messages)}") }
    end
  end

  def down
    # Never recreate the old expression: it rejects writes containing malformed legacy JSON strings.
    with_build_timeouts do
      with_retries { execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(MESSAGE_INDEX_NAME)}") }
    end
  end

  private

  def ensure_safe_message_index
    return if safe_message_index?

    with_retries do
      existing = index_metadata
      if existing
        unless ActiveModel::Type::Boolean.new.cast(existing.fetch('on_messages'))
          raise ActiveRecord::MigrationError, "#{MESSAGE_INDEX_NAME} exists on an unexpected table"
        end

        # The old index rejects malformed serialized attributes on INSERT/UPDATE, so it must be removed first.
        execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(MESSAGE_INDEX_NAME)}")
      end

      add_index :messages, MESSAGE_INDEX_EXPRESSION, using: :gin, name: MESSAGE_INDEX_NAME,
                                                        algorithm: :concurrently
    end

    return if safe_message_index?

    raise ActiveRecord::MigrationError, "#{MESSAGE_INDEX_NAME} is not the expected valid safe GIN index"
  end

  def safe_message_index?
    metadata = index_metadata
    return false unless metadata

    definition = metadata.fetch('definition')
    valid = ActiveModel::Type::Boolean.new.cast(metadata.fetch('indisvalid'))
    on_messages = ActiveModel::Type::Boolean.new.cast(metadata.fetch('on_messages'))
    expected_expression = SAFE_INDEX_DEFINITION_FRAGMENTS.all? { |fragment| definition.include?(fragment) }
    valid && on_messages && expected_expression
  end

  def index_metadata
    select_one(<<~SQL.squish)
      SELECT pg_index.indisvalid,
             pg_index.indrelid = #{quote('messages')}::regclass AS on_messages,
             pg_get_indexdef(pg_index.indexrelid) AS definition
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(MESSAGE_INDEX_NAME)}
        AND pg_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def with_retries
    attempts = 0
    begin
      attempts += 1
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if attempts >= ATTEMPTS

      say("search index repair is busy, attempt #{attempts} of #{ATTEMPTS} cancelled; trying again in #{RETRY_PAUSE}s")
      sleep(RETRY_PAUSE)
      retry
    end
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
