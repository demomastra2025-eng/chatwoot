class Captain::Documents::ChunkEmbeddingBackfillService
  def initialize(account_id: nil, assistant_id: nil, batch_size: 100)
    @account_id = account_id
    @assistant_id = assistant_id
    @batch_size = batch_size
  end

  def perform
    enqueued = 0
    scope.find_each(batch_size: @batch_size) do |chunk|
      Captain::Llm::UpdateEmbeddingJob.perform_later(chunk, chunk.content)
      enqueued += 1
    end

    { enqueued: enqueued }
  end

  private

  def scope
    chunks = Captain::DocumentChunk.needs_embedding_reindex
    chunks = chunks.where(account_id: @account_id) if @account_id.present?
    chunks = chunks.where(assistant_id: @assistant_id) if @assistant_id.present?
    chunks
  end
end
