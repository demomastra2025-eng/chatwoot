class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content)
    account_id = record.account_id
    embedding = Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(content)
    record.update!(embedding: embedding)
  rescue Captain::Llm::EmbeddingService::EmbeddingsUnavailableError => e
    Rails.logger.warn "Skipping Captain embedding update: #{e.message}"
  end
end
