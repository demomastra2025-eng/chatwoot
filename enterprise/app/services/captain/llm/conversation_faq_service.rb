class Captain::Llm::ConversationFaqService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  # Two FAQs are the same FAQ when their texts (question: answer) are this close (cosine distance 0.05 = similarity 0.95): the new FAQ
  # is then not saved. A wrongly dropped FAQ is lost knowledge, a wrongly kept one is reviewed before it is approved, so the number is
  # strict. Checked 27.10 with google/gemini-embedding-001 at 1536 numbers on the FAQs of five clinics (250 rows; three clinics share
  # one set of 67): the most similar pair of different FAQs of one clinic is 0.924 (the FAQs written from a template, one per doctor or
  # branch, are 0.88-0.92 close), the median nearest neighbour is 0.87, and 249 of the 250 FAQs have a neighbour above 0.7. The former
  # number (0.3, similarity 0.7) was set for text-embedding-3-large, whose median nearest neighbour is 0.70 (124 of 250 above 0.7);
  # with Gemini it would drop almost every new FAQ.
  DISTANCE_THRESHOLD = 0.05
  MAX_OUTPUT_TOKENS = 4096

  def initialize(assistant, conversation, content: nil, raise_on_error: false)
    super()
    @assistant = assistant
    @conversation = conversation
    @content_overridden = !content.nil?
    @content = content || conversation.to_llm_text
    @raise_on_error = raise_on_error
  end

  # Generates and deduplicates FAQs from conversation content
  # Skips processing if there was no human interaction
  def generate_and_deduplicate
    return [] if no_human_interaction?

    new_faqs = generate
    return [] if new_faqs.empty?

    duplicate_faqs, unique_faqs = find_and_separate_duplicates(new_faqs)
    save_new_faqs(unique_faqs)
    log_duplicate_faqs(duplicate_faqs) if Rails.env.development?
  end

  private

  attr_reader :content, :conversation, :assistant

  def no_human_interaction?
    return !transcript_text_has_caller_label?(content) if @content_overridden

    conversation.first_reply_created_at.nil? && !voice_transcript_interaction?
  end

  def voice_transcript_interaction?
    voice_message_transcript_interaction? || call_session_transcript_interaction?
  end

  def voice_message_transcript_interaction?
    conversation.messages.voice_calls.any? do |message|
      data = message.content_attributes.to_h['data'] || {}
      voice_transcript_has_caller_turn?(data['transcript_items']) || transcript_text_has_caller_label?(data['transcript'])
    end
  end

  def transcript_text_has_caller_label?(transcript)
    transcript.to_s.match?(/(^|\n)\s*(Клиент|Пользователь|User|Caller|Customer|Contact)\s*:/i)
  end

  def call_session_transcript_interaction?
    conversation.telephony_call_sessions.any? do |call_session|
      voice_transcript_has_caller_turn?(call_session_transcript_items(call_session))
    end
  end

  def call_session_transcript_items(call_session)
    call_session.metadata&.dig('ai_voice', 'transcript', 'final_items') ||
      call_session.metadata&.dig('ai_voice', 'final_transcript')
  end

  def voice_transcript_has_caller_turn?(items)
    Array(items).any? do |item|
      item = item.to_h
      item['text'].present? && item['speaker'].to_s.in?(%w[caller customer contact user])
    end
  end

  def find_and_separate_duplicates(faqs)
    duplicate_faqs = []
    unique_faqs = []

    faqs.each do |faq|
      lexical_duplicates = find_lexical_duplicates(faq)
      similar_faqs = lexical_duplicates.presence || find_embedding_duplicates(faq)

      if similar_faqs.any?
        duplicate_faqs << { faq: faq, similar_faqs: similar_faqs }
      else
        unique_faqs << faq
      end
    end

    [duplicate_faqs, unique_faqs]
  end

  def find_embedding_duplicates(faq)
    combined_text = "#{faq['question']}: #{faq['answer']}"
    embedder = Captain::Llm::EmbeddingService.new(account_id: @conversation.account_id)
    embedding = embedder.get_embedding(combined_text, input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    find_similar_faqs(embedding, embedder.embedding_model)
  end

  # Only the FAQs whose vector was made by the model that embeds the new one are compared with it.
  def find_similar_faqs(embedding, model)
    similar_faqs = deduplication_responses
                   .where.not(embedding: nil)
                   .where(embedding_model: model)
                   .nearest_neighbors(:embedding, embedding, distance: 'cosine')
    Rails.logger.debug(similar_faqs.map { |faq| [faq.question, faq.neighbor_distance] })
    similar_faqs.select { |record| record.neighbor_distance < DISTANCE_THRESHOLD }
  end

  def find_lexical_duplicates(faq)
    question = normalize_faq_text(faq['question'])
    answer = normalize_faq_text(faq['answer'])
    return [] if question.blank? && answer.blank?

    deduplication_responses.order(id: :desc).limit(500).select do |record|
      existing_question = normalize_faq_text(record.question)
      existing_answer = normalize_faq_text(record.answer)
      question_match = question.present? && question == existing_question
      answer_match = answer.length >= 8 && answer == existing_answer
      question_match || answer_match
    end
  end

  def normalize_faq_text(value)
    value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:punct:]\s]+/, ' ').strip
  end

  def deduplication_responses
    Captain::AssistantResponse
      .where(account_id: conversation.account_id, status: %w[pending approved])
      .visible_to_assistant(assistant.id)
  end

  def save_new_faqs(faqs)
    faqs.map do |faq|
      assistant.responses.create!(
        question: faq['question'],
        answer: faq['answer'],
        status: 'pending',
        documentable: conversation
      )
    end
  end

  def log_duplicate_faqs(duplicate_faqs)
    return if duplicate_faqs.empty?

    Rails.logger.info "Found #{duplicate_faqs.length} duplicate FAQs:"
    duplicate_faqs.each do |duplicate|
      Rails.logger.info(
        "Q: #{duplicate[:faq]['question']}\n" \
        "A: #{duplicate[:faq]['answer']}\n\n" \
        "Similar existing FAQs: #{duplicate[:similar_faqs].map { |f| "Q: #{f.question} A: #{f.answer}" }.join(', ')}"
      )
    end
  end

  def generate
    response = instrument_llm_call(instrumentation_params) do
      llm_chat = apply_chat_features(
        chat,
        schema: Captain::Llm::Schemas::FaqCollection
      ).with_instructions(system_prompt).with_params(max_tokens: MAX_OUTPUT_TOKENS)

      ask_chat(llm_chat, @content)
    end
    parse_response(response.content)
  rescue RubyLLM::Error, Llm::StructuredOutputPolicy::StructuredOutputError => e
    raise if @raise_on_error

    Rails.logger.error "LLM API Error: #{e.message}"
    []
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.conversation_faq',
      model: model,
      temperature: @temperature,
      account_id: @conversation.account_id,
      conversation_id: @conversation.display_id,
      feature_name: 'conversation_faq',
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: @content }
      ],
      metadata: { assistant_id: @assistant.id }
    }
  end

  def system_prompt
    account_language = @conversation.account.locale_english_name
    Captain::Llm::SystemPromptsService.conversation_faq_generator(account_language)
  end

  def llm_feature_key
    :assistant
  end

  def llm_model_account
    @conversation.account
  end

  def parse_response(response)
    return [] unless response.is_a?(Hash)

    Array(response.with_indifferent_access[:faqs])
  rescue StandardError => e
    Rails.logger.error "Error in parsing conversation FAQ response: #{e.message}"
    []
  end
end
