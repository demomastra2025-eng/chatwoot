class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  MAX_TEXT_CHUNKS = 20

  def perform(document, options = {})
    return unless document.faq_generation_enabled?

    generation_fingerprint = document_generation_fingerprint(document)
    faqs = generate_faqs(document, options)
    document.with_lock do
      document.reload
      if current_generation?(document, generation_fingerprint)
        reset_previous_responses(document)
        create_responses_from_faqs(faqs, document)
      end
    end
  end

  private

  def generate_faqs(document, options)
    if should_use_pagination?(document)
      generate_paginated_faqs(document, options)
    else
      generate_text_faqs(document)
    end
  end

  def generate_paginated_faqs(document, options)
    service = build_paginated_service(document, options)
    faqs = service.generate
    store_paginated_metadata(document, service)
    faqs
  end

  def generate_text_faqs(document)
    chunks = text_chunks(document.faq_generation_text, document)
    return [] if chunks.blank?

    faqs = chunks.each_with_index.flat_map do |chunk, index|
      Captain::Llm::FaqGeneratorService.new(
        chunk,
        document.account.locale_english_name,
        account_id: document.account_id
      ).generate.map do |faq|
        faq.to_h.merge('source_chunk' => { 'chunk_index' => index, 'content' => chunk })
      end
    end
    store_text_generation_metadata(document, chunks) if chunks.many?
    deduplicate_faqs(faqs)
  end

  def text_chunks(text, document)
    chunk_size = Captain::KnowledgeSettings.chunk_size_for(document.account)

    text.to_s.scan(Regexp.new(".{1,#{chunk_size}}", Regexp::MULTILINE)).first(MAX_TEXT_CHUNKS)
  end

  def store_text_generation_metadata(document, chunks)
    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'method' => 'text_chunks',
          'chunks_processed' => chunks.size,
          'chunk_size' => Captain::KnowledgeSettings.chunk_size_for(document.account),
          'source_text_bytes' => document.faq_generation_text.to_s.bytesize,
          'timestamp' => Time.current.iso8601
        }
      )
    )
  end

  def current_generation?(document, generation_fingerprint)
    document.faq_generation_enabled? && document_generation_fingerprint(document) == generation_fingerprint
  end

  def document_generation_fingerprint(document)
    Digest::SHA256.hexdigest([document.pdf_document?, document.faq_generation_text.to_s].join(':'))
  end

  def persist_source_chunks(document, faqs)
    source_chunks = faqs.filter_map { |faq| faq.to_h.with_indifferent_access[:source_chunk] }
                        .uniq { |source_chunk| source_chunk.with_indifferent_access[:chunk_index] }

    source_chunks.each_with_object({}) do |source_chunk, chunks_by_index|
      normalized = source_chunk.with_indifferent_access
      chunks_by_index[normalized[:chunk_index]] = document.document_chunks.create!(
        account: document.account,
        assistant: document.assistant,
        chunk_index: normalized[:chunk_index],
        content: normalized[:content]
      )
    end
  end

  def build_paginated_service(document, options)
    Captain::Llm::PaginatedFaqGeneratorService.new(
      document,
      pages_per_chunk: options[:pages_per_chunk],
      max_pages: options[:max_pages],
      language: document.account.locale_english_name
    )
  end

  def store_paginated_metadata(document, service)
    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'method' => 'paginated',
          'pages_processed' => service.total_pages_processed,
          'iterations' => service.iterations_completed,
          'timestamp' => Time.current.iso8601
        }
      )
    )
  end

  def create_responses_from_faqs(faqs, document)
    source_chunks_by_index = persist_source_chunks(document, faqs)
    faqs.each { |faq| create_response(faq, document, source_chunks_by_index) }
  end

  def deduplicate_faqs(faqs)
    Array(faqs).select { |faq| faq_question(faq).present? }.uniq { |faq| faq_question(faq).downcase }
  end

  def faq_question(faq)
    faq.to_h.with_indifferent_access[:question].to_s.strip
  end

  def should_use_pagination?(document)
    document.pdf_document? && document.source_text.blank?
  end

  def reset_previous_responses(response_document)
    response_document.responses.destroy_all
    response_document.document_chunks.destroy_all
  end

  def create_response(faq, document, source_chunks_by_index = {})
    normalized = faq.to_h.with_indifferent_access
    source_chunk = normalized.delete(:source_chunk)
    document_chunk = source_chunk && source_chunks_by_index[source_chunk.with_indifferent_access[:chunk_index]]
    document.responses.create!(
      question: normalized[:question],
      answer: normalized[:answer],
      assistant: document.assistant,
      documentable: document,
      document_chunk: document_chunk
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error I18n.t('captain.documents.response_creation_error', error: e.message)
  end
end
