class ReRunCacheLabelJob < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  MigrationConversation = Class.new(ActiveRecord::Base) do
    self.table_name = 'conversations'
  end

  def up # rubocop:disable Metrics/MethodLength
    # Rebuild before the current Account/Conversation models are compatible with this schema.
    # Async GlobalIDs could be consumed and discarded before later migrations finish.
    # The historical varchar(255) cache cannot hold every valid combination of labels.
    change_column :conversations, :cached_label_list, :text if connection.column_exists?(:conversations, :cached_label_list, :string)

    MigrationConversation.where(cached_label_list: nil).in_batches(of: 1000, use_ranges: true) do |batch|
      execute <<~SQL.squish
        UPDATE conversations AS conversation
        SET cached_label_list = label_lists.names
        FROM (
          SELECT conversation.id, COALESCE(labels.names, '') AS names
          FROM conversations AS conversation
          JOIN accounts AS account ON account.id = conversation.account_id AND account.status = 0
          LEFT JOIN LATERAL (
            SELECT string_agg(first_labels.name, ', ' ORDER BY first_labels.tagging_id) AS names
            FROM (
              SELECT DISTINCT ON (lower(btrim(tag.name))) btrim(tag.name) AS name, tagging.id AS tagging_id
              FROM taggings AS tagging
              JOIN tags AS tag ON tag.id = tagging.tag_id
              WHERE tagging.taggable_type = 'Conversation' AND tagging.taggable_id = conversation.id
                AND tagging.context = 'labels' AND tagging.tagger_id IS NULL
                AND NULLIF(btrim(tag.name), '') IS NOT NULL
              ORDER BY lower(btrim(tag.name)), tagging.id
            ) AS first_labels
          ) AS labels ON true
          WHERE conversation.id IN (#{batch.select(:id).to_sql}) AND conversation.cached_label_list IS NULL
        ) AS label_lists
        WHERE conversation.id = label_lists.id
      SQL
    end
  end

  def down
    # Cached labels may have changed since the backfill; do not clear them.
  end
end
