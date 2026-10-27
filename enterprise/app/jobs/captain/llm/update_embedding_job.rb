class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
    account_id = record.account_id
    embedding_service = Captain::Llm::EmbeddingService.new(account_id: account_id)
    return if embedding_current?(record, content, embedding_service)

    embedding = embedding_service.get_embedding(content, input_type: input_type)
    return unless update_embedding_success(record, embedding, expected_content: content, embedding_service: embedding_service)

    log_embedding_success(record, content, embedding, input_type, embedding_service.embedding_model)
  rescue Captain::Llm::EmbeddingService::EmbeddingsError => e
    current_request = if record.respond_to?(:embedding_status=)
                        update_embedding_failure(record, e, expected_content: content)
                      else
                        with_current_embedding_content(record, content) { nil }
                      end
    return unless current_request

    Rails.logger.warn "Skipping Captain embedding update: #{e.message}"
    raise unless record.respond_to?(:embedding_status=) || e.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError)
  end

  private

  # A row that remembers the checksum of its embedded text keeps its vector when the text and the model are still the same: a save that
  # did not change the text (or a repeated request) costs no call to the model.
  def embedding_current?(record, content, embedding_service)
    return false unless record.respond_to?(:embedding_checksum) && record.embedding_checksum.present? && record.embedding.present?

    record.embedding_checksum == Captain::Llm::EmbeddingService.checksum(content) &&
      record.embedding_model == embedding_service.embedding_model
  end

  def update_embedding_success(record, embedding, expected_content:, embedding_service:)
    with_current_embedding_content(record, expected_content) do
      attributes = { embedding: embedding }.merge(embedding_source_attributes(record, expected_content, embedding_service))
      if record.respond_to?(:embedding_status=)
        record.update!(attributes.merge(embedding_status: :indexed, embedding_error: nil, embedding_updated_at: Time.current))
      else
        record.update!(attributes)
      end
    end
  end

  # Which model made the vector (and, where the table keeps it, the checksum of the text): a vector of another model is never
  # compared with a query of this one, see Captain::Llm::EmbeddingReindexService.
  def embedding_source_attributes(record, content, embedding_service)
    attributes = {}
    attributes[:embedding_model] = embedding_service.embedding_model if record.respond_to?(:embedding_model=)
    attributes[:embedding_checksum] = Captain::Llm::EmbeddingService.checksum(content) if record.respond_to?(:embedding_checksum=)
    attributes
  end

  def update_embedding_failure(record, error, expected_content:)
    return false unless record.respond_to?(:embedding_status=)

    with_current_embedding_content(record, expected_content) do
      record.update!(embedding_status: :failed, embedding_error: error.message.truncate(500))
    end
  end

  def with_current_embedding_content(record, expected_content)
    applied = false
    record.with_lock do
      next unless embedding_content(record) == expected_content

      yield
      applied = true
    end
    applied
  rescue ActiveRecord::RecordNotFound
    false
  end

  def embedding_content(record)
    case record
    when Captain::DocumentChunk
      record.content
    when Captain::AssistantResponse
      "#{record.question}: #{record.answer}"
    when ArticleEmbedding
      record.term
    end
  end

  def log_embedding_success(record, content, embedding, input_type, model)
    payload = embedding_log_payload(record, content, embedding, input_type, model)
    Rails.logger.info("[Captain::Llm::UpdateEmbeddingJob] Indexed Captain embedding: #{payload}")
  end

  def embedding_log_payload(record, content, embedding, input_type, model)
    {
      record: record.class.name,
      record_id: record_id(record),
      account_id: record.account_id,
      model: model,
      vector_dimensions: Array(embedding).length,
      configured_vector_dimensions: Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS,
      input_type: input_type,
      chunk_count: indexed_chunk_count(record, content),
      estimated_tokens: estimated_tokens_for(content),
      content_chars: content.to_s.length
    }.compact
  end

  def record_id(record)
    record.id if record.respond_to?(:id)
  end

  def indexed_chunk_count(record, content)
    return 1 if record.instance_of?(Captain::DocumentChunk)
    return record.document_chunks.count if record.respond_to?(:document_chunks)
    return content.count if content.is_a?(Array)

    1
  end

  def estimated_tokens_for(content)
    (content.to_s.length / Captain::KnowledgeSettings::CHARS_PER_TOKEN_ESTIMATE).ceil
  end
end
