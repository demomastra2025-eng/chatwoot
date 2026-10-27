# What holds vectors in the product and what each vector is made from. The one list that the re-embedding, its backup and its status
# read, see Captain::Llm::EmbeddingReindexService.
module Captain::Llm::EmbeddingSources
  KEYS = %w[faq cache articles chunks services].freeze
  CLASSES = {
    'faq' => 'Captain::AssistantResponse', 'cache' => 'Captain::KnowledgeAnswerCacheEntry', 'articles' => 'ArticleEmbedding',
    'chunks' => 'Captain::DocumentChunk', 'services' => 'Scheduling::Service'
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

  # The cache keeps queries (they are embedded as queries); everything else is a document.
  def input_type(key)
    key == 'cache' ? Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE : Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE
  end

  # The columns of a table that describe its vector: what the backup keeps and a restore puts back.
  def vector_columns(key)
    columns = %w[embedding embedding_model]
    columns << 'embedding_checksum' if CHECKSUM_KEYS.include?(key)
    columns << 'embedded_at' if EMBEDDED_AT_KEYS.include?(key)
    columns
  end

  # The rows to embed. Only the cache entries and the knowledge chunks that already have a vector are re-embedded: the others are
  # indexed by their own jobs when they are made.
  def rows(key)
    send("#{key}_rows").reject { |row| row.text.blank? }
  end

  def faq_rows
    Captain::AssistantResponse.pluck(:id, :account_id, :question, :answer).map { |id, account, q, a| Row.new(id, account, "#{q}: #{a}") }
  end

  def cache_rows
    rows_of(Captain::KnowledgeAnswerCacheEntry.where.not(embedding: nil), :query)
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

  def rows_of(relation, text_column)
    relation.pluck(:id, :account_id, text_column).map { |id, account, text| Row.new(id, account, text) }
  end
end
