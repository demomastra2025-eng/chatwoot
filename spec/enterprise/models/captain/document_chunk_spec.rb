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
    embedding_service = instance_double(Captain::Llm::EmbeddingService)
    expect(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
    expect(embedding_service).to receive(:get_embedding)
      .with('refund policy', input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
      .and_return(embedding)

    results = described_class.search('refund policy', account_id: account.id)

    expect(results.to_sql).to include('"captain_document_chunks"."account_id" =')
    expect(results.to_sql).to include('"captain_document_chunks"."embedding_status" =')
  end

  it 'does not run semantic search without an account scope' do
    expect(Captain::Llm::EmbeddingService).not_to receive(:new)

    expect(described_class.search('refund policy')).to be_empty
  end

  describe '.visible_to_assistant' do
    it 'returns workspace-owned and selected assistant chunks without leaking another assistant personal chunks' do
      general_document = create(:captain_document, account: account, assistant: nil, visibility: :general)
      workspace_personal_document = create(:captain_document, account: account, assistant: nil, visibility: :personal)
      assistant_personal_document = create(:captain_document, account: account, assistant: assistant, visibility: :personal)
      other_personal_document = create(
        :captain_document,
        account: account,
        assistant: create(:captain_assistant, account: account),
        visibility: :personal
      )
      general_chunk = create(:captain_document_chunk, account: account, assistant: nil, document: general_document)
      workspace_personal_chunk = create(:captain_document_chunk, account: account, assistant: nil, document: workspace_personal_document)
      assistant_personal_chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: assistant_personal_document)
      other_personal_chunk = create(
        :captain_document_chunk,
        account: account,
        assistant: other_personal_document.assistant,
        document: other_personal_document
      )

      expect(described_class.visible_to_assistant(assistant.id)).to include(
        general_chunk,
        workspace_personal_chunk,
        assistant_personal_chunk
      )
      expect(described_class.visible_to_assistant(assistant.id)).not_to include(other_personal_chunk)
      expect(described_class.visible_to_assistant(nil)).to include(general_chunk, workspace_personal_chunk)
      expect(described_class.visible_to_assistant(nil)).not_to include(assistant_personal_chunk, other_personal_chunk)
    end
  end
end
