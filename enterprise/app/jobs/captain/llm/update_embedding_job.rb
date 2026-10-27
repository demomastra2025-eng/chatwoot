class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
    embedding_service = Captain::Llm::EmbeddingService.new(account_id: record.account_id)
    return if embedding_current?(record, content, embedding_service)

    embedding = embedding_service.get_embedding(content, input_type: input_type)
    result = update_embedding_success(record, embedding, expected_content: content, embedding_service: embedding_service)
    # the vector of the old model is not stored after the switch: the text is embedded again with the new model
    return self.class.perform_later(record, content, input_type: input_type) if result == :model_changed

    log_embedding_success(record, content, embedding, input_type, embedding_service.embedding_model) if result
  rescue Captain::Llm::EmbeddingService::EmbeddingsError => e
    handle_embedding_error(record, content, e)
  end

  private

  def handle_embedding_error(record, content, error)
    status_record = record.respond_to?(:embedding_status=)
    current_request = if status_record
                        update_embedding_failure(record, error, expected_content: content)
                      else
                        with_current_embedding_content(record, content) { true }
                      end
    return unless current_request

    Rails.logger.warn "Skipping Captain embedding update: #{error.message}"
    raise error unless status_record || error.is_a?(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError)
  end

  # A row that remembers the checksum of its embedded text keeps its vector when the text and the model are still the same: a save that
  # did not change the text (or a repeated request) costs no call to the model.
  def embedding_current?(record, content, embedding_service)
    return false unless record.respond_to?(:embedding_checksum) && record.embedding_checksum.present? && record.embedding.present?

    record.embedding_checksum == Captain::Llm::EmbeddingService.checksum(content) &&
      record.embedding_model == embedding_service.embedding_model
  end

  # true when the vector was stored, false when the text changed or the record is gone, :model_changed when the platform embedding
  # model was switched while the vector was being made (the full re-embedding, see Captain::Llm::EmbeddingReindexService): a vector of
  # the old model must not be stored after the switch, the job runs again with the new model.
  def update_embedding_success(record, embedding, expected_content:, embedding_service:)
    with_current_embedding_content(record, expected_content) do
      next :model_changed unless model_in_force?(record, embedding_service)

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

  def model_in_force?(record, embedding_service)
    Captain::Llm::EmbeddingService.new(account_id: record.account_id).embedding_model == embedding_service.embedding_model
  end

  def update_embedding_failure(record, error, expected_content:)
    return false unless record.respond_to?(:embedding_status=)

    with_current_embedding_content(record, expected_content) do
      record.update!(embedding_status: :failed, embedding_error: error.message.truncate(500))
    end
  end

  # Runs the block under the lock of the record, only while the record still has the text that was embedded; returns the value of the
  # block, or false when the text changed or the record is gone.
  def with_current_embedding_content(record, expected_content)
    result = false
    record.with_lock do
      next unless embedding_content(record) == expected_content

      result = yield
    end
    result
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
      content_chars: content.to_s.length,
      over_model_limit: over_model_limit?(model, content)
    }.compact
  end

  # The model ignores the text after its first `max_input_tokens` tokens (config/llm.yml) without an error: a chunk over the limit is
  # embedded by its beginning only. true when the text is longer than that, nil when the limit is not known or not reached.
  def over_model_limit?(model, content)
    limit = Llm::Models::CONFIG.dig('models', model.to_s, 'max_input_tokens')
    limit.present? && content.to_s.length * Captain::Llm::EmbeddingService::TOKENS_PER_CHAR > limit ? true : nil
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
