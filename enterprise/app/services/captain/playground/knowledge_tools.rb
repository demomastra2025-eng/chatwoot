# Snapshot lookups use only the session JSON. Production payload formatters are
# called with plain objects, never with database-backed records or lookup services.
module Captain::Playground::KnowledgeTools
  ArticleSnapshot = Struct.new(:id, :title, :description, :content, :slug, :locale, :status, :category_id, :portal_id, :author_id,
                               :views, :meta, :created_at, :updated_at, :portal, :author, keyword_init: true)
  FaqSnapshot = Struct.new(:id, :question, :answer, :document_chunk_id, :created_at, :updated_at, :documentable, :neighbor_distance,
                          keyword_init: true)
  ChunkSnapshot = Struct.new(:id, :document_id, :chunk_index, :content, :embedding_status, :created_at, :updated_at, :document, keyword_init: true)
  CannedSnapshot = Struct.new(:id, :short_code, :content, :created_at, :updated_at, keyword_init: true)
  SourceSnapshot = Struct.new(:name, :external_link, keyword_init: true)
  DocumentSnapshot = Struct.new(:id, :name, :source_mode, :status, :content_type, :file_size, :sendable, :filename, :external_link,
                               keyword_init: true) do
    def sendable_file? = sendable == true
    def sendable_filename = filename
  end

  private

  def search_documentation
    query = knowledge_query!
    matches, = knowledge_matches(query)
    formatter = Captain::Tools::SearchDocumentationService.allocate
    payloads = matches.map do |record|
      if record['type'] == 'document_chunk'
        formatter.send(:structured_document_chunk_payload, knowledge_chunk_snapshot(record))
      else
        formatter.send(:structured_response_payload, knowledge_faq_snapshot(record))
      end
    end
    { query: query, translated_query: query, lookup_strategy: 'lexical', total_count: matches.size, matches: payloads,
      retrieval_trace: knowledge_trace(matches, strategy: 'lexical'), simulated: true }
  end

  def faq_lookup
    query = knowledge_query!
    matches, strategy = knowledge_matches(query, exact: true)
    formatter = Captain::Tools::Copilot::FaqLookupService.allocate
    payloads = matches.map do |record|
      if record['type'] == 'document_chunk'
        formatter.send(:document_chunk_payload, knowledge_chunk_snapshot(record))
      else
        formatter.send(:response_payload, knowledge_faq_snapshot(record), lookup_strategy: strategy)
      end
    end
    { query: query, translated_query: query, total_count: matches.size, result: matches.any? ? 'found' : 'not_found',
      message: matches.any? ? nil : 'No relevant FAQ result found', lookup_strategy: strategy, matches: payloads,
      retrieval_trace: knowledge_trace(matches, strategy: strategy), simulated: true }.compact
  end

  def captain_documents
    documents = knowledge_records('knowledge_documents').select do |record|
      record['status'] == 'available' && record['source_document'] != false &&
        knowledge_text_match?(record, %w[name external_link], @args['query'])
    end.sort_by { |record| [-knowledge_timestamp(record['created_at']), -record['id'].to_i] }
    documents = documents.first(knowledge_limit(default: 10, max: 20))
    documents.select! { |record| record['sendable'] == true } if ActiveModel::Type::Boolean.new.cast(@args['sendable_only'])
    formatter = Captain::Tools::Copilot::ListCaptainDocumentsService.allocate
    session_id = @session.id
    # A simulated artifact can never become a production DocumentArtifactToken.
    formatter.define_singleton_method(:document_artifact_id) { |document| "trial_#{session_id}_document_#{document.id}" }
    payloads = documents.map { |record| formatter.send(:document_payload, knowledge_snapshot(DocumentSnapshot, record)) }
    { action: 'list_captain_documents', documents: payloads, simulated: true }
  end

  def article_details
    record = knowledge_records('articles').find { |article| article['id'].to_s == @args.fetch('article_id').to_s }
    return Captain::ToolResult.failure(error: 'Article not found', retryable: false) unless record

    { article: knowledge_article_payload(record, details: true), simulated: true }
  end

  def search_articles
    category_id = @args['category_id'].presence
    if category_id && knowledge_records('categories').none? { |category| category['id'].to_s == category_id.to_s }
      raise ArgumentError, 'Unknown category_id for this session. Omit category_id unless a verified category ID was provided.'
    end
    status = @args['status'].presence || 'published'
    records = knowledge_records('articles').select do |record|
      record['status'] == status && (!category_id || record['category_id'].to_s == category_id.to_s) &&
        knowledge_text_match?(record, %w[title content], @args['query'])
    end.sort_by { |record| [-knowledge_timestamp(record['updated_at']), -record['id'].to_i] }
    { filters: { query: @args['query'], category_id: category_id, status: status }.compact, total_count: records.size,
      articles: records.first(knowledge_limit).map { |record| knowledge_article_payload(record) }, simulated: true }
  end

  def search_canned_responses
    records = knowledge_records('canned_responses').select do |record|
      knowledge_text_match?(record, %w[short_code content], @args['query'])
    end.sort_by { |record| [record['short_code'].to_s, record['id'].to_i] }
    formatter = Captain::Tools::Copilot::SearchCannedResponsesService.allocate
    payloads = records.first(knowledge_limit).map do |record|
      formatter.send(:canned_response_payload, knowledge_snapshot(CannedSnapshot, record))
    end
    { filters: { query: @args['query'].presence }.compact, total_count: records.size, canned_responses: payloads, simulated: true }
  end

  def knowledge_matches(query, exact: false)
    faqs = knowledge_records('faq_responses').select { |record| record['status'] == 'approved' }
                  .sort_by { |record| [-knowledge_timestamp(record['created_at']), -record['id'].to_i] }
    exact_matches = faqs.select { |record| record['question'].to_s.strip.downcase == query.downcase } if exact
    return [exact_matches.first(5).map { |record| record.merge('type' => 'faq_response') }, 'lexical_exact'] if exact_matches.present?

    tokens = Captain::AssistantResponse.send(:lexical_tokens, query)
    faqs.select! { |record| tokens.any? { |token| knowledge_text_match?(record, %w[question answer], token) } }
    return [faqs.first(5).map { |record| record.merge('type' => 'faq_response') }, 'lexical'] if faqs.any?

    documents = knowledge_records('knowledge_documents').index_by { |record| record['id'] }
    chunks = knowledge_records('knowledge_chunks').select do |record|
      documents.key?(record['document_id']) && tokens.any? { |token| record['content'].to_s.downcase.include?(token) }
    end.sort_by { |record| [record['document_id'].to_i, record['chunk_index'].to_i, record['id'].to_i] }
    [chunks.first(5).map { |record| record.merge('type' => 'document_chunk') }, 'lexical']
  end

  def knowledge_trace(matches, strategy:)
    { strategy: strategy, degraded: false, semantic_attempted: false, match_count: matches.size,
      response_ids: matches.select { |record| record['type'] == 'faq_response' }.pluck('id'),
      document_ids: matches.filter_map { |record| record['document_id'] }.uniq,
      document_chunk_ids: matches.filter_map { |record| record['type'] == 'document_chunk' ? record['id'] : record['document_chunk_id'] }.uniq,
      sources: matches.filter_map { |record| knowledge_source(record)&.external_link }.uniq }
  end

  def knowledge_records(collection)
    Array(@data[collection]).select { |record| record['visible'] != false }
  end

  def knowledge_query!
    query = @args['query'].to_s.squish
    raise ArgumentError, 'query is required' if query.blank?

    query
  end

  def knowledge_limit(default: Captain::Tools::Copilot::BaseAccountTool::MAX_RESULTS, max: Captain::Tools::Copilot::BaseAccountTool::MAX_RESULTS)
    Captain::Tools::Copilot::BaseAccountTool.allocate.send(:parse_limit, @args['limit'], default: default, max: max)
  end

  def knowledge_text_match?(record, fields, query)
    query.blank? || fields.any? { |field| record[field].to_s.downcase.include?(query.to_s.downcase) }
  end

  def knowledge_timestamp(value)
    value.present? ? Time.iso8601(value.to_s).to_f : 0
  end

  def knowledge_snapshot(klass, record, **overrides)
    values = klass.members.index_with { |key| record[key.to_s] }
    %i[created_at updated_at].each do |key|
      values[key] = Time.iso8601(values[key].to_s) if values[key].present?
    end
    klass.new(**values.merge(overrides))
  end

  def knowledge_source(record)
    document = knowledge_records('knowledge_documents').find { |item| item['id'] == record['document_id'] }
    link = record['source'].presence || document&.fetch('external_link', nil)
    SourceSnapshot.new(external_link: link) if link
  end

  def knowledge_faq_snapshot(record)
    knowledge_snapshot(FaqSnapshot, record, documentable: knowledge_source(record))
  end

  def knowledge_chunk_snapshot(record)
    knowledge_snapshot(ChunkSnapshot, record, document: knowledge_source(record) || SourceSnapshot.new)
  end

  def knowledge_article_payload(record, details: false)
    article = knowledge_snapshot(ArticleSnapshot, record, portal: SourceSnapshot.new(name: record['portal_name']),
                                author: SourceSnapshot.new(name: record['author_name']))
    formatter = details ? Captain::Tools::Copilot::GetArticleService : Captain::Tools::Copilot::SearchArticlesService
    formatter.allocate.send(:article_payload, article)
  end
end
