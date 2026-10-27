# frozen_string_literal: true

# One embedding model for the whole platform (google/gemini-embedding-001 at 1536 numbers): the services get a vector of their own
# (the service search is a vector search), and every table that holds vectors remembers which model made them, so that a vector of
# another model is never compared with a query of this one. The FAQ also keeps the checksum of the embedded text: a save that did
# not change the text does not call the model again.
class AddServiceEmbeddingsAndEmbeddingModelNames < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduling_services, :embedding, :vector, limit: 1536
    add_column :scheduling_services, :embedding_model, :string
    add_column :scheduling_services, :embedding_checksum, :string
    add_column :scheduling_services, :embedded_at, :datetime

    add_column :captain_assistant_responses, :embedding_model, :string
    add_column :captain_assistant_responses, :embedding_checksum, :string
    add_column :captain_knowledge_answer_cache_entries, :embedding_model, :string
    add_column :article_embeddings, :embedding_model, :string
    add_column :captain_document_chunks, :embedding_model, :string
  end
end
