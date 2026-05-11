class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  TEXT_CHUNK_SIZE = 50_000
  MAX_TEXT_CHUNKS = 20

  def perform(document, options = {})
    return unless document.faq_generation_enabled?

    reset_previous_responses(document)

    faqs = generate_faqs(document, options)
    create_responses_from_faqs(faqs, document)
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
    chunks = text_chunks(document.faq_generation_text)
    return [] if chunks.blank?

    faqs = chunks.flat_map do |chunk|
      Captain::Llm::FaqGeneratorService.new(chunk, document.account.locale_english_name, account_id: document.account_id).generate
    end
    store_text_generation_metadata(document, chunks) if chunks.many?
    deduplicate_faqs(faqs)
  end

  def text_chunks(text)
    text.to_s.scan(/.{1,#{TEXT_CHUNK_SIZE}}/mo).first(MAX_TEXT_CHUNKS)
  end

  def store_text_generation_metadata(document, chunks)
    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'method' => 'text_chunks',
          'chunks_processed' => chunks.size,
          'source_text_bytes' => document.faq_generation_text.to_s.bytesize,
          'timestamp' => Time.current.iso8601
        }
      )
    )
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
    faqs.each { |faq| create_response(faq, document) }
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
  end

  def create_response(faq, document)
    normalized = faq.to_h.with_indifferent_access
    document.responses.create!(
      question: normalized[:question],
      answer: normalized[:answer],
      assistant: document.assistant,
      documentable: document
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error I18n.t('captain.documents.response_creation_error', error: e.message)
  end
end
