class AddIdempotencyKeyToReminders < ActiveRecord::Migration[7.1]
  TABLE_NAME = :reminders
  COLUMN_NAME = 'idempotency_key'
  INDEX_NAME = 'idx_reminders_on_account_idempotency_key'
  INDEX_COLUMNS = %w[account_id idempotency_key].freeze
  INDEX_PREDICATE = 'idempotency_key IS NOT NULL'

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
      add_column TABLE_NAME, COLUMN_NAME, :string
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
    if existing
      unless index_matches_contract?(existing)
        raise ActiveRecord::MigrationError,
              "Existing index #{INDEX_NAME} does not match the reminder idempotency contract"
      end
      return
    end

    conflicting = connection.indexes(TABLE_NAME).find do |index|
      index.columns.map(&:to_s) == INDEX_COLUMNS
    end
    if conflicting
      raise ActiveRecord::MigrationError,
            "Existing index #{conflicting.name} conflicts with the reminder idempotency contract"
    end

    add_index TABLE_NAME, INDEX_COLUMNS,
              unique: true,
              where: INDEX_PREDICATE,
              name: INDEX_NAME
  end

  def index_matches_contract?(index)
    index.columns.map(&:to_s) == INDEX_COLUMNS && index.unique &&
      normalize_predicate(index.where) == normalize_predicate(INDEX_PREDICATE) &&
      (!index.respond_to?(:valid) || index.valid)
  end

  def normalize_predicate(predicate)
    predicate.to_s.downcase.gsub(/[\s()]/, '')
  end
end
