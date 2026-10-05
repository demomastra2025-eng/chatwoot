class AddIdempotencyKeyToReminders < ActiveRecord::Migration[7.1]
  # A nullable column is a metadata change, taken under a lock timeout (retried) like 20260928110000. The unique index is
  # built CONCURRENTLY, so reminders stay writable while it is built (a plain CREATE INDEX blocks every write for as long
  # as the build takes), and an INVALID index left by an interrupted build is rebuilt instead of failing the deploy.
  disable_ddl_transaction!

  TABLE_NAME = :reminders
  COLUMN_NAME = 'idempotency_key'
  INDEX_NAME = 'idx_reminders_on_account_idempotency_key'
  INDEX_COLUMNS = %w[account_id idempotency_key].freeze
  INDEX_PREDICATE = 'idempotency_key IS NOT NULL'
  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  STATEMENT_TIMEOUT = '30min'.freeze

  def up
    unless table_exists?(TABLE_NAME)
      raise ActiveRecord::MigrationError, 'The reminders table must exist before adding its idempotency key'
    end

    ensure_idempotency_key_column!
    ensure_idempotency_key_index!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Reminder idempotency keys are retained for delivery safety'
  end

  private

  def ensure_idempotency_key_column!
    column = connection.columns(TABLE_NAME).find { |candidate| candidate.name == COLUMN_NAME }
    unless column
      with_short_lock_timeout { add_column TABLE_NAME, COLUMN_NAME, :string }
      return
    end

    matches_contract = column.type == :string && column.limit.nil? && column.null &&
                       column.default.nil? && column.default_function.nil?
    return if matches_contract

    raise ActiveRecord::MigrationError,
          "Existing #{TABLE_NAME}.#{COLUMN_NAME} does not match the nullable string contract"
  end

  def ensure_idempotency_key_index!
    existing = connection.indexes(TABLE_NAME).find { |index| index.name == INDEX_NAME }
    existing ? verify_existing_index!(existing) : create_idempotency_key_index!
  end

  def verify_existing_index!(existing)
    unless index_matches_contract?(existing)
      raise ActiveRecord::MigrationError,
            "Existing index #{INDEX_NAME} does not match the reminder idempotency contract"
    end

    rebuild_invalid_index! unless existing.valid?
  end

  def create_idempotency_key_index!
    conflicting = connection.indexes(TABLE_NAME).find do |index|
      index.columns.map(&:to_s) == INDEX_COLUMNS
    end
    if conflicting
      raise ActiveRecord::MigrationError,
            "Existing index #{conflicting.name} conflicts with the reminder idempotency contract"
    end

    without_statement_timeout do
      add_index TABLE_NAME, INDEX_COLUMNS,
                unique: true,
                where: INDEX_PREDICATE,
                name: INDEX_NAME,
                algorithm: :concurrently
    end
  end

  def index_matches_contract?(index)
    index.columns.map(&:to_s) == INDEX_COLUMNS && index.unique &&
      normalize_predicate(index.where) == normalize_predicate(INDEX_PREDICATE)
  end

  def rebuild_invalid_index!
    without_statement_timeout { execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(INDEX_NAME)}") }
  end

  def normalize_predicate(predicate)
    predicate.to_s.downcase.gsub(/[\s()]/, '')
  end

  def with_short_lock_timeout
    attempt = 0
    begin
      attempt += 1
      transaction do
        execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= LOCK_ATTEMPTS

      sleep(attempt)
      retry
    end
  end

  def without_statement_timeout
    previous = select_value('SHOW statement_timeout')
    execute("SET statement_timeout = '#{STATEMENT_TIMEOUT}'")
    yield
  ensure
    execute("SET statement_timeout = #{quote(previous)}") if previous
  end
end
