class Captain::Llm::PaginatedFaqGeneratorService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  # Default pages per chunk - easily configurable
  DEFAULT_PAGES_PER_CHUNK = 10
  MAX_ITERATIONS = 20 # Safety limit to prevent infinite loops

  attr_reader :total_pages_processed, :iterations_completed

  def initialize(document, options = {})
    super()
    @document = document
    @language = options[:language] || 'english'
    @pages_per_chunk = options[:pages_per_chunk] || DEFAULT_PAGES_PER_CHUNK
    @max_pages = options[:max_pages] # Optional limit from UI
    @total_pages_processed = 0
    @iterations_completed = 0
  end

  def generate
    raise CustomExceptions::Pdf::FaqGenerationError, 'PDF source is missing' if pdf_source.blank?

    generate_paginated_faqs
  end

  # Method to check if we should continue processing
  def should_continue_processing?(last_chunk_result)
    # Stop if we've hit the maximum iterations
    return false if @iterations_completed >= MAX_ITERATIONS

    # Stop if we've processed the maximum pages specified
    return false if @max_pages && @total_pages_processed >= @max_pages

    # Stop if the last chunk returned no FAQs (likely no more content)
    return false if last_chunk_result[:faqs].empty?

    # Stop if the LLM explicitly indicates no more content
    return false if last_chunk_result[:has_content] == false

    # Continue processing
    true
  end

  private

  attr_reader :document

  def generate_paginated_faqs
    all_faqs = []
    current_page = 1

    loop do
      end_page = calculate_end_page(current_page)
      chunk_result = process_chunk_and_update_state(current_page, end_page, all_faqs)

      break unless should_continue_processing?(chunk_result)

      current_page = end_page + 1
    end

    deduplicate_faqs(all_faqs)
  end

  def calculate_end_page(current_page)
    end_page = current_page + @pages_per_chunk - 1
    @max_pages && end_page > @max_pages ? @max_pages : end_page
  end

  def process_chunk_and_update_state(current_page, end_page, all_faqs)
    chunk_result = process_page_chunk(current_page, end_page)
    chunk_faqs = chunk_result[:faqs]

    all_faqs.concat(chunk_faqs)
    @total_pages_processed = end_page
    @iterations_completed += 1

    chunk_result
  end

  def process_page_chunk(start_page, end_page)
    prompt = page_chunk_prompt(start_page, end_page)

    instrumentation_params = build_instrumentation_params(prompt, start_page, end_page)

    response = instrument_llm_call(instrumentation_params) do
      ask_chat(chat_with_structured_response, build_user_content(prompt))
    end

    result = parse_chunk_response(response.content)
    { faqs: result['faqs'] || [], has_content: result['has_content'] != false }
  rescue RubyLLM::Error, Llm::StructuredOutputPolicy::StructuredOutputError => e
    Rails.logger.error I18n.t('captain.documents.page_processing_error', start: start_page, end: end_page, error: e.message)
    { faqs: [], has_content: false }
  end

  def build_user_content(prompt)
    RubyLLM::Content.new(prompt, pdf_source)
  end

  def page_chunk_prompt(start_page, end_page)
    Captain::Llm::SystemPromptsService.paginated_faq_generator(start_page, end_page, @language)
  end

  def chat_with_structured_response
    apply_chat_features(
      chat(model: model),
      schema: Captain::Llm::Schemas::PaginatedFaqChunk
    )
  end

  def parse_chunk_response(content)
    return { 'faqs' => [], 'has_content' => false } unless content.is_a?(Hash)

    normalized = content.with_indifferent_access
    {
      'faqs' => Array(normalized[:faqs]),
      'has_content' => normalized[:has_content] == true
    }
  rescue StandardError => e
    Rails.logger.error "Error parsing chunk response: #{e.message}"
    { 'faqs' => [], 'has_content' => false }
  end

  def deduplicate_faqs(faqs)
    valid_faqs = faqs.select { |faq| faq_question(faq).present? }

    # Remove exact duplicates
    unique_faqs = valid_faqs.uniq { |faq| faq_question(faq).downcase }

    # Remove similar questions
    final_faqs = []
    unique_faqs.each do |faq|
      similar_exists = final_faqs.any? do |existing|
        similarity_score(faq_question(existing), faq_question(faq)) > 0.85
      end

      final_faqs << faq unless similar_exists
    end

    Rails.logger.info "Deduplication: #{faqs.size} → #{final_faqs.size} FAQs"
    final_faqs
  end

  def faq_question(faq)
    faq.to_h['question'].to_s.strip
  end

  def similarity_score(str1, str2)
    words1 = str1.to_s.downcase.split(/\W+/).reject(&:empty?)
    words2 = str2.to_s.downcase.split(/\W+/).reject(&:empty?)
    common_words = words1 & words2
    total_words = (words1 + words2).uniq.size
    return 0 if total_words.zero?

    common_words.size.to_f / total_words
  end

  def build_instrumentation_params(params, start_page, end_page)
    {
      span_name: 'llm.paginated_faq_generation',
      account_id: @document&.account_id,
      feature_name: 'paginated_faq_generation',
      model: model,
      messages: [{ role: 'user', content: params }],
      metadata: {
        document_id: @document&.id,
        start_page: start_page,
        end_page: end_page,
        iteration: @iterations_completed + 1
      }
    }
  end

  def pdf_source
    return document.pdf_file if document.pdf_file.attached?
    return document.external_link if document.remote_pdf_url?

    nil
  end

  def llm_feature_key
    :assistant
  end

  def llm_model_account
    document.account
  end

  def resolved_model
    Llm::Config.model_for(
      feature: llm_feature_key,
      account: llm_model_account,
      fallback: Llm::Config::DEFAULT_MODEL
    )
  end
end
