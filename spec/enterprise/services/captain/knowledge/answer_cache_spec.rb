require 'rails_helper'

RSpec.describe Captain::Knowledge::AnswerCache do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let!(:chunk) do
    document.document_chunks.create!(account: account, assistant: assistant, chunk_index: 0, content: 'Refund policy source')
  end
  let(:payload) do
    {
      'query' => 'refund policy',
      'lookup_strategy' => 'semantic_chunk',
      'total_count' => 1,
      'matches' => [{ 'type' => 'document_chunk', 'document_chunk_id' => chunk.id, 'answer' => chunk.content }],
      'retrieval_trace' => {
        'strategy' => 'semantic_chunk',
        'degraded' => false,
        'document_chunk_ids' => [chunk.id]
      }
    }
  end
  let(:embedding) { Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1) }

  before do
    embedding_service = instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
  end

  it 'stores cacheable semantic knowledge payloads and exposes store trace' do
    result = described_class.new(account: account, assistant: assistant, query: 'Refund policy').write(payload)

    entry = Captain::KnowledgeAnswerCacheEntry.last
    expect(entry).to have_attributes(account_id: account.id, assistant_id: assistant.id, query: 'refund policy')
    expect(entry.payload.dig('retrieval_trace', 'answer_cache')).to be_nil
    expect(result.dig('retrieval_trace', 'answer_cache')).to include(
      'enabled' => true,
      'hit' => false,
      'stored' => true,
      'entry_id' => entry.id
    )
  end

  it 'returns exact cache hits without recomputing retrieval' do
    described_class.new(account: account, assistant: assistant, query: 'Refund policy').write(payload)

    result = described_class.new(account: account, assistant: assistant, query: ' refund   policy ').fetch

    expect(result).to include('lookup_strategy' => 'semantic_chunk', 'total_count' => 1)
    expect(result.dig('retrieval_trace', 'answer_cache')).to include(
      'enabled' => true,
      'hit' => true,
      'match' => 'exact',
      'hit_count' => 1
    )
  end

  it 'does not cache degraded lexical fallback payloads' do
    degraded_payload = payload.merge(
      'lookup_strategy' => 'lexical',
      'retrieval_trace' => payload['retrieval_trace'].merge('strategy' => 'lexical', 'degraded' => true)
    )

    described_class.new(account: account, assistant: assistant, query: 'Refund policy').write(degraded_payload)

    expect(Captain::KnowledgeAnswerCacheEntry.count).to eq(0)
  end

  it 'rejects mismatched account and assistant cache rows' do
    other_account = create(:account)
    entry = Captain::KnowledgeAnswerCacheEntry.new(
      account: other_account,
      assistant: assistant,
      query: 'refund policy',
      query_sha256: Digest::SHA256.hexdigest('refund policy'),
      source_fingerprint: 'fingerprint',
      payload: payload
    )

    expect(entry).not_to be_valid
    expect(entry.errors[:assistant]).to include('must belong to the same account')
  end

  it 'can serve semantic cache matches through the vector entry boundary' do
    entry = described_class.new(account: account, assistant: assistant, query: 'Refund policy').write(payload)
    cache_entry = Captain::KnowledgeAnswerCacheEntry.last
    allow(Captain::KnowledgeAnswerCacheEntry).to receive(:semantic_match).and_return(cache_entry)

    result = described_class.new(account: account, assistant: assistant, query: 'How do refunds work?').fetch

    expect(result.dig('retrieval_trace', 'answer_cache')).to include(
      'hit' => true,
      'match' => 'semantic',
      'entry_id' => cache_entry.id
    )
    expect(entry.dig('retrieval_trace', 'answer_cache')).to include('stored' => true)
  end
end
