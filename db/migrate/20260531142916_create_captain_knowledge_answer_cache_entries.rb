class CreateCaptainKnowledgeAnswerCacheEntries < ActiveRecord::Migration[7.1]
  def change
    create_cache_table
    add_cache_indexes
  end

  private

  def create_cache_table
    create_table :captain_knowledge_answer_cache_entries do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :assistant, null: false, foreign_key: { to_table: :captain_assistants, on_delete: :cascade }
      t.text :query, null: false
      t.string :query_sha256, null: false
      t.vector :embedding, limit: 1536
      t.jsonb :payload, null: false, default: {}
      t.string :source_fingerprint, null: false
      t.integer :hit_count, null: false, default: 0
      t.datetime :last_hit_at
      t.datetime :expires_at
      t.timestamps
    end
  end

  def add_cache_indexes
    add_index :captain_knowledge_answer_cache_entries,
              [:account_id, :assistant_id, :query_sha256, :source_fingerprint],
              unique: true,
              name: 'idx_captain_answer_cache_exact'
    add_index :captain_knowledge_answer_cache_entries, :expires_at, name: 'idx_captain_answer_cache_expires_at'
    add_index :captain_knowledge_answer_cache_entries,
              :embedding,
              using: :ivfflat,
              name: 'vector_idx_captain_answer_cache_embedding',
              opclass: :vector_l2_ops
  end
end
