class AddTranscriptionSearchIndexes < ActiveRecord::Migration[7.1]
  # The conversation-list transcript search checks several legacy fields. Keep their indexed superset in one message
  # expression, and index attachment transcripts separately so the historical fallback can union candidate message IDs.
  # The runtime exact predicate is still applied after the candidate IDs are found.
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

  INDEXES = [
    # Rails passes string expressions through verbatim and does not apply its opclass option to them, so include the
    # operator class in the expression string after grouping the indexed expression for PostgreSQL.
    { table: :messages, name: 'index_messages_on_transcription_search_text', expression: "(#{MESSAGE_SEARCH_TEXT}) gin_trgm_ops" },
    { table: :attachments, name: 'index_attachments_on_transcribed_text', expression: "(meta ->> 'transcribed_text') gin_trgm_ops" }
  ].freeze
  BUILD_STATEMENT_TIMEOUT = '30min'.freeze
  LOCK_TIMEOUT = '5s'.freeze
  ATTEMPTS = 5
  RETRY_PAUSE = 10 # seconds

  def up
    with_build_timeouts do
      INDEXES.each { |index| build_index(index) }
      INDEXES.map { |index| index.fetch(:table) }.uniq.each do |table|
        with_retries { execute("ANALYZE #{quote_table_name(table)}") }
      end
    end
  end

  def down
    with_build_timeouts do
      INDEXES.each do |index|
        with_retries { execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(index.fetch(:name))}") }
      end
    end
  end

  private

  def build_index(index)
    table = index.fetch(:table)
    name = index.fetch(:name)
    return false if index_valid?(name)

    with_retries do
      drop_invalid_index!(name)
      add_index table, index.fetch(:expression), using: :gin, name: name,
                                                          algorithm: :concurrently, if_not_exists: true
    end
    true
  end

  def index_valid?(name)
    ActiveModel::Type::Boolean.new.cast(select_value(<<~SQL.squish))
      SELECT pg_index.indisvalid
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(name)} AND pg_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def drop_invalid_index!(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(name)} AND pg_namespace.nspname = ANY (current_schemas(false))
        AND NOT pg_index.indisvalid
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(name)}") if invalid.present?
  end

  def with_retries
    attempts = 0
    begin
      attempts += 1
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if attempts >= ATTEMPTS

      say("search index build is busy, attempt #{attempts} of #{ATTEMPTS} cancelled; trying again in #{RETRY_PAUSE}s")
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
