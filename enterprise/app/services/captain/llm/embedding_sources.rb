# What holds vectors in the product and what each vector is made from. The one list that the re-embedding, its backup and its status
# read, see Captain::Llm::EmbeddingReindexService.
module Captain::Llm::EmbeddingSources
  KEYS = %w[faq articles chunks services].freeze
  CLASSES = {
    'faq' => 'Captain::AssistantResponse', 'articles' => 'ArticleEmbedding', 'chunks' => 'Captain::DocumentChunk',
    'services' => 'Scheduling::Service'
  }.freeze
  # The tables that also remember the checksum of the embedded text, and the one that remembers when the vector was made.
  CHECKSUM_KEYS = %w[faq services].freeze
  EMBEDDED_AT_KEYS = %w[services].freeze

  # id: the row; account_id: whose key and rules embed it; text: exactly what is embedded.
  Row = Struct.new(:id, :account_id, :text)

  module_function

  def table_name(key)
    CLASSES.fetch(key).constantize.table_name
  end

  # Everything that holds vectors holds documents (the questions are embedded as queries when they are asked).
  def input_type(_key)
    Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE
  end

  # The columns of a table that describe its vector: what the backup keeps and a restore puts back.
  def vector_columns(key)
    columns = %w[embedding embedding_model]
    columns << 'embedding_checksum' if CHECKSUM_KEYS.include?(key)
    columns << 'embedded_at' if EMBEDDED_AT_KEYS.include?(key)
    columns
  end

  # The rows to embed. Only the knowledge chunks that already have a vector are re-embedded: the others are indexed by their own
  # jobs when they are made.
  def rows(key)
    send("#{key}_rows").reject { |row| row.text.blank? }
  end

  def faq_rows
    Captain::AssistantResponse.pluck(:id, :account_id, :question, :answer).map { |id, account, q, a| Row.new(id, account, "#{q}: #{a}") }
  end

  def articles_rows
    ArticleEmbedding.joins(:article).pluck('article_embeddings.id', 'articles.account_id', 'article_embeddings.term')
                    .map { |id, account, text| Row.new(id, account, text) }
  end

  def chunks_rows
    rows_of(Captain::DocumentChunk.where.not(embedding: nil), :content)
  end

  def services_rows
    Scheduling::Service.find_each.map { |service| Row.new(service.id, service.account_id, Scheduling::ServiceIndex.text(service)) }
  end

  # Locks the rows (in id order) until the end of the current transaction: a save of one of them waits, so that what is stored for it is
  # the vector of the text it has.
  def lock_rows!(key, ids)
    return if ids.empty?

    ActiveRecord::Base.connection.select_values(
      ActiveRecord::Base.sanitize_sql_array(["SELECT id FROM #{table_name(key)} WHERE id IN (?) ORDER BY id FOR UPDATE", ids])
    )
  end

  # The rows that have no current vector of `model`: no vector, a vector of another model (or of none), a vector that a service search
  # cannot use (no `embedded_at`), or, in the tables that keep the checksum of the embedded text, a vector made from another text than
  # the row has now. A row whose checksum was never recorded is judged by its model alone (the migration marked the existing vectors
  # with their model only).
  def stale_rows(key, model)
    state = vector_state(key)
    rows(key).select { |row| stale?(key, row, state.fetch(row.id, [nil, nil, false, false]), model) }
  end

  # id => [model, checksum, has a vector, the vector is usable] of every row of the table.
  def vector_state(key)
    checksum = CHECKSUM_KEYS.include?(key) ? 'embedding_checksum' : 'NULL'
    usable = EMBEDDED_AT_KEYS.include?(key) ? 'embedded_at IS NOT NULL' : 'TRUE'
    ActiveRecord::Base.connection.select_rows(
      "SELECT id, embedding_model, #{checksum}, embedding IS NOT NULL, #{usable} FROM #{table_name(key)}"
    ).to_h { |id, vector_model, vector_checksum, vector, ok| [id.to_i, [vector_model, vector_checksum, vector, ok]] }
  end

  def stale?(key, row, state, model)
    vector_model, vector_checksum, vector, usable = state
    return true if !vector || !usable || vector_model != model

    CHECKSUM_KEYS.include?(key) && vector_checksum.present? && vector_checksum != Captain::Llm::EmbeddingService.checksum(row.text)
  end

  def rows_of(relation, text_column)
    relation.pluck(:id, :account_id, text_column).map { |id, account, text| Row.new(id, account, text) }
  end
end
