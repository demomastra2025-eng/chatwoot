class AddEmbeddingStateToCaptainDocumentChunks < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_document_chunks, :embedding, :vector, limit: 1536
    add_column :captain_document_chunks, :embedding_status, :integer, null: false, default: 0
    add_column :captain_document_chunks, :embedding_error, :text
    add_column :captain_document_chunks, :embedding_updated_at, :datetime

    add_index :captain_document_chunks, :embedding_status
    add_index :captain_document_chunks, :embedding, using: :ivfflat, name: 'vector_idx_captain_document_chunks_embedding', opclass: :vector_l2_ops
  end
end
