# Non-transactional specs commit their rows, and Account#destroy! leaves most
# of them to destroy_async jobs that never run in specs. Truncating is only
# safe on a throwaway test database, so anything else is refused.
module CommittedRowsCleanup
  PRESERVED_TABLES = %w[schema_migrations ar_internal_metadata].freeze
  # chatwoot_test, plus numbered or parallel copies such as chatwoot_test2.
  TEST_DATABASE_NAME = /_test(?:[-_]?\d+)?\z/

  module_function

  # One atomic TRUNCATE of every table satisfies the foreign keys by itself.
  # ActiveRecord's truncate_tables disables all triggers around it instead and
  # leaves them disabled when the statement fails, which breaks display ids
  # for every later spec.
  def truncate!(connection = ActiveRecord::Base.connection)
    database = connection.current_database.to_s
    raise "Refusing to truncate #{database}: not a test database" unless Rails.env.test? && database.match?(TEST_DATABASE_NAME)

    tables = (connection.tables - PRESERVED_TABLES).map { |table| connection.quote_table_name(table) }
    connection.transaction do
      # Truncating every table can outlast the 14s request statement timeout on a busy host.
      connection.execute("SET LOCAL statement_timeout = '120s'")
      connection.execute("TRUNCATE TABLE #{tables.join(', ')}")
    end
  end
end
