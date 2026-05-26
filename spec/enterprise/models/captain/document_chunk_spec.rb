require 'rails_helper'

RSpec.describe Captain::DocumentChunk, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }

  it 'enqueues embedding generation for new chunks' do
    expect(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later) do |record, content|
      expect(record).to be_a(described_class)
      expect(content).to eq('Refund policy source text')
    end

    create(:captain_document_chunk, account: account, assistant: assistant, document: document, content: 'Refund policy source text')
  end

  it 'marks content changes as stale before reindexing' do
    chunk = create(
      :captain_document_chunk,
      account: account,
      assistant: assistant,
      document: document,
      embedding_status: :indexed,
      embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1)
    )

    chunk.update!(content: 'Updated source text')

    expect(chunk.reload.embedding_status).to eq('stale')
  end

  it 'searches indexed chunk embeddings scoped to account' do
    embedding = Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1)
    embedding_service = instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding)
    expect(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)

    results = described_class.search('refund policy', account_id: account.id)

    expect(results.to_sql).to include('"captain_document_chunks"."account_id" =')
    expect(results.to_sql).to include('"captain_document_chunks"."embedding_status" =')
  end

  it 'does not run semantic search without an account scope' do
    expect(Captain::Llm::EmbeddingService).not_to receive(:new)

    expect(described_class.search('refund policy')).to be_empty
  end
end
