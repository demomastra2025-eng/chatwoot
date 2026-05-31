class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
    account_id = record.account_id
    embedding_service = Captain::Llm::EmbeddingService.new(account_id: account_id)
    embedding = embedding_service.get_embedding(content, input_type: input_type)
    update_embedding_success(record, embedding)
    log_embedding_success(record, content, embedding, input_type, embedding_service.embedding_model)
  rescue Captain::Llm::EmbeddingService::EmbeddingsError => e
    update_embedding_failure(record, e)
    Rails.logger.warn "Skipping Captain embedding update: #{e.message}"
    raise unless record.respond_to?(:embedding_status=) || e.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError)
  end

  private

  def update_embedding_success(record, embedding)
    if record.respond_to?(:embedding_status=)
      record.update!(embedding: embedding, embedding_status: :indexed, embedding_error: nil, embedding_updated_at: Time.current)
    else
      record.update!(embedding: embedding)
    end
  end

  def update_embedding_failure(record, error)
    return unless record.respond_to?(:embedding_status=)

    record.update!(embedding_status: :failed, embedding_error: error.message.truncate(500))
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
