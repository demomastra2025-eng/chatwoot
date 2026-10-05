class CreateCaptainFollowUpAttempts < ActiveRecord::Migration[7.1]
  # The table is created without foreign keys and each key is added NOT VALID in its own short transaction under a lock
  # timeout (retried), like 20260928110050: a long transaction on conversations or messages, which every inbound message
  # touches, can then neither stall this DDL for the full statement timeout nor queue the writers behind it. A missing
  # index is built concurrently, and an INVALID one left by an interrupted build is rebuilt instead of being accepted.
  disable_ddl_transaction!

  TABLE_NAME = :captain_follow_up_attempts
  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5

  COLUMN_CONTRACT = [
    { name: 'id', type: :integer, limit: 8, null: false, primary_key: true },
    { name: 'account_id', type: :integer, limit: 8, null: false },
    { name: 'assistant_id', type: :integer, limit: 8, null: false },
    { name: 'conversation_id', type: :integer, limit: 8, null: false },
    { name: 'anchor_message_id', type: :integer, limit: 8, null: false },
    { name: 'step_index', type: :integer, limit: 4, null: false },
    { name: 'attempt_key', type: :string, limit: 64, null: false },
    { name: 'generated_content', type: :text, null: true },
    { name: 'status', type: :string, limit: nil, null: false, default: 'processing' },
    { name: 'processing_started_at', type: :datetime, null: false, precision: [nil, 6] },
    { name: 'generated_at', type: :datetime, null: true, precision: [nil, 6] },
    { name: 'completed_at', type: :datetime, null: true, precision: [nil, 6] },
    { name: 'expires_at', type: :datetime, null: false, precision: [nil, 6] },
    { name: 'created_at', type: :datetime, null: false, precision: [nil, 6] },
    { name: 'updated_at', type: :datetime, null: false, precision: [nil, 6] }
  ].freeze

  INDEX_CONTRACT = [
    { name: 'index_captain_follow_up_attempts_on_account_id', columns: %w[account_id], unique: false },
    { name: 'index_captain_follow_up_attempts_on_assistant_id', columns: %w[assistant_id], unique: false },
    { name: 'index_captain_follow_up_attempts_on_conversation_id', columns: %w[conversation_id], unique: false },
    { name: 'index_captain_follow_up_attempts_on_anchor_message_id', columns: %w[anchor_message_id], unique: false },
    { name: 'index_captain_follow_up_attempts_on_attempt_key', columns: %w[attempt_key], unique: true },
    {
      name: 'index_captain_follow_up_attempts_on_anchor_and_created_at',
      columns: %w[anchor_message_id created_at], unique: false
    },
    { name: 'index_captain_follow_up_attempts_on_status_and_expires_at', columns: %w[status expires_at], unique: false }
  ].freeze

  FOREIGN_KEY_CONTRACT = [
    { column: 'account_id', to_table: 'accounts' },
    { column: 'assistant_id', to_table: 'captain_assistants' },
    { column: 'conversation_id', to_table: 'conversations' },
    { column: 'anchor_message_id', to_table: 'messages' }
  ].freeze

  def up
    create_attempts_table unless table_exists?(TABLE_NAME)

    validate_attempt_columns!
    ensure_attempt_indexes!
    ensure_attempt_foreign_keys!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Captain follow-up attempts are retained as execution history'
  end

  private

  def create_attempts_table
    transaction do
      create_table TABLE_NAME do |t|
        t.references :account, null: false, foreign_key: false
        t.references :assistant, null: false, foreign_key: false
        t.references :conversation, null: false, foreign_key: false
        t.references :anchor_message, null: false, foreign_key: false
        t.integer :step_index, null: false
        t.string :attempt_key, null: false, limit: 64
        t.text :generated_content
        t.string :status, null: false, default: 'processing'
        t.datetime :processing_started_at, null: false
        t.datetime :generated_at
        t.datetime :completed_at
        t.datetime :expires_at, null: false
        t.timestamps
      end
    end
  end

  def validate_attempt_columns!
    columns = connection.columns(TABLE_NAME).index_by(&:name)
    expected_order = COLUMN_CONTRACT.map { |column| column.fetch(:name) }
    unless columns.keys.take(expected_order.length) == expected_order
      raise ActiveRecord::MigrationError,
            "Existing #{TABLE_NAME} column order does not match the Captain attempt contract"
    end

    COLUMN_CONTRACT.each do |expected|
      column = columns[expected.fetch(:name)]
      unless column
        raise ActiveRecord::MigrationError, "Existing #{TABLE_NAME} is missing required column #{expected.fetch(:name)}"
      end

      unless column.type == expected.fetch(:type) && column.null == expected.fetch(:null)
        raise ActiveRecord::MigrationError,
              "Existing #{TABLE_NAME}.#{column.name} type or nullability does not match the Captain attempt contract"
      end

      if expected.key?(:limit) && column.limit != expected[:limit]
        raise ActiveRecord::MigrationError,
              "Existing #{TABLE_NAME}.#{column.name} length does not match the Captain attempt contract"
      end

      if expected.key?(:precision) && !Array(expected[:precision]).include?(column.precision)
        raise ActiveRecord::MigrationError,
              "Existing #{TABLE_NAME}.#{column.name} precision does not match the Captain attempt contract"
      end

      validate_column_default!(column, expected)
    end

    return if connection.primary_key(TABLE_NAME) == 'id'

    raise ActiveRecord::MigrationError, "Existing #{TABLE_NAME} primary key does not match the Captain attempt contract"
  end

  def validate_column_default!(column, expected)
    if expected[:primary_key]
      expected_default = "nextval('#{TABLE_NAME}_id_seq'::regclass)"
      return if column.default_function == expected_default
    elsif expected.key?(:default)
      return if column.default == expected[:default].to_s && column.default_function.nil?
    elsif !expected[:primary_key]
      return if column.default.nil? && column.default_function.nil?
    else
      return
    end

    raise ActiveRecord::MigrationError,
          "Existing #{TABLE_NAME}.#{column.name} default does not match the Captain attempt contract"
  end

  def ensure_attempt_indexes!
    INDEX_CONTRACT.each do |expected|
      existing = connection.indexes(TABLE_NAME).find { |index| index.name == expected.fetch(:name) }
      existing ? verify_existing_index!(existing, expected) : create_missing_index!(expected)
    end
  end

  def verify_existing_index!(existing, expected)
    unless index_matches?(existing, expected)
      raise ActiveRecord::MigrationError,
            "Existing index #{expected.fetch(:name)} does not match the Captain attempt contract"
    end

    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(existing.name)}") unless existing.valid?
  end

  def create_missing_index!(expected)
    conflicting = connection.indexes(TABLE_NAME).find { |index| index.columns.map(&:to_s) == expected.fetch(:columns) }
    if conflicting
      raise ActiveRecord::MigrationError,
            "Existing index #{conflicting.name} conflicts with the Captain attempt contract"
    end

    add_index TABLE_NAME, expected.fetch(:columns),
              name: expected.fetch(:name), unique: expected.fetch(:unique), algorithm: :concurrently
  end

  def index_matches?(index, expected)
    index.columns.map(&:to_s) == expected.fetch(:columns) && index.unique == expected.fetch(:unique) && index.where.nil?
  end

  def ensure_attempt_foreign_keys!
    FOREIGN_KEY_CONTRACT.each do |expected|
      existing = connection.foreign_keys(TABLE_NAME).select { |key| key.column == expected.fetch(:column) }
      existing.any? ? verify_existing_foreign_key!(existing, expected) : add_foreign_key_without_lock_queue!(expected)
    end
  end

  def verify_existing_foreign_key!(existing, expected)
    matching = existing.one? && existing.first.to_table == expected.fetch(:to_table) &&
               existing.first.primary_key.to_s == 'id' &&
               existing.first.on_delete == :cascade
    unless matching
      raise ActiveRecord::MigrationError,
            "Existing #{TABLE_NAME}.#{expected.fetch(:column)} foreign key does not match the Captain attempt contract"
    end

    # A key left NOT VALID by an interrupted run is validated; VALIDATE CONSTRAINT lets writers continue.
    validate_foreign_key(TABLE_NAME, name: existing.first.name) unless existing.first.validated?
  end

  def add_foreign_key_without_lock_queue!(expected)
    column_name = expected.fetch(:column)
    with_short_lock_timeout do
      add_foreign_key TABLE_NAME, expected.fetch(:to_table), column: column_name, on_delete: :cascade, validate: false
    end
    validate_foreign_key TABLE_NAME, column: column_name
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
end
