class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
    account_id = record.account_id
    embedding = Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(content, input_type: input_type)
    update_embedding_success(record, embedding)
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
end
