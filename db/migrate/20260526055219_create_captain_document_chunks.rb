class CreateCaptainDocumentChunks < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_document_chunks do |t|
      t.references :account, null: false, index: true, foreign_key: true
      t.references :assistant, null: false, index: true, foreign_key: { to_table: :captain_assistants }
      t.references :document, null: false, index: true, foreign_key: { to_table: :captain_documents }
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.string :content_sha256, null: false

      t.timestamps
    end

    add_index :captain_document_chunks, [:document_id, :chunk_index], unique: true
    add_index :captain_document_chunks, :content_sha256
    add_reference :captain_assistant_responses, :document_chunk,
                  index: true,
                  foreign_key: { to_table: :captain_document_chunks, on_delete: :nullify }
  end
end
