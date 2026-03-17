class AddUniqueInboxSourceIdIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_messages_unique_inbox_source_id'.freeze

  def up
    deduplicate_messages!
    add_index :messages,
              %i[inbox_id source_id],
              unique: true,
              where: 'source_id IS NOT NULL',
              algorithm: :concurrently,
              name: INDEX_NAME
  end

  def down
    remove_index :messages, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def deduplicate_messages!
    execute <<~SQL.squish
      DELETE FROM messages
      WHERE id IN (
        SELECT id
        FROM (
          SELECT id,
                 ROW_NUMBER() OVER (PARTITION BY inbox_id, source_id ORDER BY id ASC) AS duplicate_rank
          FROM messages
          WHERE source_id IS NOT NULL
        ) duplicates
        WHERE duplicates.duplicate_rank > 1
      )
    SQL
  end
end
