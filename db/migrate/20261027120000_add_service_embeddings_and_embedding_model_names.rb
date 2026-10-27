# frozen_string_literal: true

# One embedding model for the whole platform (google/gemini-embedding-001 at 1536 numbers): the services get a vector of their own
# (the service search is a vector search), and every table that holds vectors remembers which model made them, so that a vector of
# another model is never compared with a query of this one. The FAQ also keeps the checksum of the embedded text: a save that did
# not change the text does not call the model again.
#
# The vectors that exist now were made by the model in force (the setting CAPTAIN_EMBEDDING_MODEL, or the built-in default of the time
# when it was never set), so they are marked with that name: the searches keep working on them until the full re-embedding switches the
# model (rake onelink:embeddings:apply). Each table change is a short, retried step bound by a lock timeout instead of queueing reads
# and writes behind a long transaction.
class AddServiceEmbeddingsAndEmbeddingModelNames < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'
  LOCK_ATTEMPTS = 5
  # The built-in default before this migration, used when the setting was never set.
  LEGACY_DEFAULT_MODEL = 'text-embedding-3-small'
  SETTING = 'CAPTAIN_EMBEDDING_MODEL'
  # The tables whose existing vectors get the name of the model that made them.
  VECTOR_TABLES = %w[captain_assistant_responses article_embeddings captain_document_chunks].freeze

  def up
    with_short_lock_timeout do
      add_column :scheduling_services, :embedding, :vector, limit: 1536, if_not_exists: true
      add_column :scheduling_services, :embedding_model, :string, if_not_exists: true
      add_column :scheduling_services, :embedding_checksum, :string, if_not_exists: true
      add_column :scheduling_services, :embedded_at, :datetime, if_not_exists: true
    end
    VECTOR_TABLES.each do |table|
      with_short_lock_timeout { add_column table, :embedding_model, :string, if_not_exists: true }
    end
    with_short_lock_timeout { add_column :captain_assistant_responses, :embedding_checksum, :string, if_not_exists: true }

    mark_existing_vectors
  end

  def down
    with_short_lock_timeout { remove_column :captain_assistant_responses, :embedding_checksum, if_exists: true }
    VECTOR_TABLES.each do |table|
      with_short_lock_timeout { remove_column table, :embedding_model, if_exists: true }
    end
    with_short_lock_timeout do
      %i[embedded_at embedding_checksum embedding_model embedding].each { |column| remove_column :scheduling_services, column, if_exists: true }
    end
  end

  private

  def mark_existing_vectors
    model = quote(configured_model)
    VECTOR_TABLES.each do |table|
      execute("UPDATE #{table} SET embedding_model = #{model} WHERE embedding IS NOT NULL AND embedding_model IS NULL")
    end
  end

  def configured_model
    InstallationConfig.find_by(name: SETTING)&.value.to_s.strip.presence || LEGACY_DEFAULT_MODEL
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
