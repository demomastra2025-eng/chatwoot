require 'rails_helper'

RSpec.describe Captain::Documents::ChunkEmbeddingBackfillService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }

  it 'enqueues only chunks that need embedding reindex' do
    pending_chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: document, embedding_status: :pending)
    failed_chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: document, embedding_status: :failed)
    indexed_chunk = create(
      :captain_document_chunk,
      account: account,
      assistant: assistant,
      document: document,
      embedding_status: :indexed,
      embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1)
    )

    expect(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later).with(pending_chunk, pending_chunk.content)
    expect(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later).with(failed_chunk, failed_chunk.content)
    expect(Captain::Llm::UpdateEmbeddingJob).not_to receive(:perform_later).with(indexed_chunk, indexed_chunk.content)

    result = described_class.new(account_id: account.id).perform

    expect(result).to include(enqueued: 2)
  end

  it 'honors account and assistant filters' do
    other_assistant = create(:captain_assistant, account: account)
    other_document = create(:captain_document, account: account, assistant: other_assistant)
    scoped_chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: document, embedding_status: :pending)
    other_chunk = create(:captain_document_chunk, account: account, assistant: other_assistant, document: other_document, embedding_status: :pending)

    expect(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later).with(scoped_chunk, scoped_chunk.content)
    expect(Captain::Llm::UpdateEmbeddingJob).not_to receive(:perform_later).with(other_chunk, other_chunk.content)

    result = described_class.new(account_id: account.id, assistant_id: assistant.id).perform

    expect(result).to include(enqueued: 1)
  end
end
