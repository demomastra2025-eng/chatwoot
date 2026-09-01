class EnforceOneCommunicationThreadPerContact < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_communication_threads_one_per_contact'.freeze
  INDEX_COLUMNS = %w[account_id contact_id].freeze

  def up
    duplicate_count = duplicate_contact_thread_group_count
    if duplicate_count.positive?
      raise ActiveRecord::MigrationError,
            "One-thread invariant blocked by #{duplicate_count} duplicate contact groups; run communication_threads:conflict_report"
    end

    existing_index = connection.indexes(:communication_threads).find { |index| index.name == INDEX_NAME }
    if existing_index
      unless existing_index.unique && existing_index.columns == INDEX_COLUMNS
        raise ActiveRecord::MigrationError, "Existing #{INDEX_NAME} has an incompatible definition"
      end
      return if postgres_index_valid?

      remove_index :communication_threads, name: INDEX_NAME, algorithm: :concurrently
    end

    add_index :communication_threads,
              INDEX_COLUMNS,
              unique: true,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :communication_threads, name: INDEX_NAME, algorithm: :concurrently if index_exists?(:communication_threads, name: INDEX_NAME)
  end

  private

  def duplicate_contact_thread_group_count
    connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM (
        SELECT account_id, contact_id
        FROM communication_threads
        GROUP BY account_id, contact_id
        HAVING COUNT(*) > 1
      ) duplicate_groups
    SQL
  end

  def postgres_index_valid?
    %w[t true 1].include?(connection.select_value(<<~SQL.squish).to_s)
      SELECT pg_index.indisvalid
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname = #{connection.quote(INDEX_NAME)}
    SQL
  end
end
