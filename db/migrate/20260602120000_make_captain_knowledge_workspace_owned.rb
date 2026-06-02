class MakeCaptainKnowledgeWorkspaceOwned < ActiveRecord::Migration[7.1]
  KNOWLEDGE_ASSISTANT_TABLES = %i[
    captain_documents
    captain_document_chunks
    captain_assistant_responses
    captain_knowledge_answer_cache_entries
  ].freeze

  def up
    make_assistant_references_nullable
    replace_assistant_foreign_key(:captain_document_chunks, on_delete: :nullify)
    replace_assistant_foreign_key(:captain_knowledge_answer_cache_entries, on_delete: :nullify)
    deduplicate_account_external_links
    replace_document_uniqueness_index(account_scoped: true)
  end

  def down
    backfill_null_assistant_ids
    replace_document_uniqueness_index(account_scoped: false)
    replace_assistant_foreign_key(:captain_document_chunks)
    replace_assistant_foreign_key(:captain_knowledge_answer_cache_entries)
    make_assistant_references_required
  end

  private

  def make_assistant_references_nullable
    KNOWLEDGE_ASSISTANT_TABLES.each do |table_name|
      change_column_null table_name, :assistant_id, true if column_exists?(table_name, :assistant_id)
    end
  end

  def make_assistant_references_required
    KNOWLEDGE_ASSISTANT_TABLES.each do |table_name|
      change_column_null table_name, :assistant_id, false if column_exists?(table_name, :assistant_id)
    end
  end

  def replace_document_uniqueness_index(account_scoped:)
    if index_named?(:captain_documents, 'index_captain_documents_on_assistant_id_and_external_link')
      remove_index :captain_documents, name: 'index_captain_documents_on_assistant_id_and_external_link'
    end

    if index_named?(:captain_documents, 'index_captain_documents_on_account_id_and_external_link')
      remove_index :captain_documents, name: 'index_captain_documents_on_account_id_and_external_link'
    end

    if account_scoped
      add_index :captain_documents,
                [:account_id, :external_link],
                unique: true,
                name: 'index_captain_documents_on_account_id_and_external_link'
    else
      add_index :captain_documents,
                [:assistant_id, :external_link],
                unique: true,
                name: 'index_captain_documents_on_assistant_id_and_external_link'
    end
  end

  def deduplicate_account_external_links
    execute <<~SQL.squish
      WITH ranked_documents AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY account_id, external_link ORDER BY id ASC) AS row_number
        FROM captain_documents
        WHERE external_link IS NOT NULL AND external_link <> ''
      )
      UPDATE captain_documents
      SET external_link = captain_documents.external_link || '#captain-legacy-duplicate-' || captain_documents.id
      FROM ranked_documents
      WHERE captain_documents.id = ranked_documents.id
        AND ranked_documents.row_number > 1
    SQL
  end

  def index_named?(table_name, index_name)
    indexes(table_name).any? { |index| index.name == index_name }
  end

  def replace_assistant_foreign_key(table_name, on_delete: nil)
    return unless column_exists?(table_name, :assistant_id)

    remove_foreign_key table_name, column: :assistant_id if foreign_key_exists?(table_name, :captain_assistants, column: :assistant_id)

    options = { column: :assistant_id }
    options[:on_delete] = on_delete if on_delete.present?
    add_foreign_key table_name, :captain_assistants, **options
  end

  def backfill_null_assistant_ids
    KNOWLEDGE_ASSISTANT_TABLES.each do |table_name|
      next unless column_exists?(table_name, :assistant_id)

      execute <<~SQL.squish
        UPDATE #{table_name} AS knowledge_item
        SET assistant_id = fallback_assistant.id
        FROM LATERAL (
          SELECT captain_assistants.id
          FROM captain_assistants
          WHERE captain_assistants.account_id = knowledge_item.account_id
          ORDER BY captain_assistants.created_at DESC, captain_assistants.id DESC
          LIMIT 1
        ) AS fallback_assistant
        WHERE knowledge_item.assistant_id IS NULL
      SQL
    end
  end
end
