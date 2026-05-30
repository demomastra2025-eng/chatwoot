require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::FaqLookupService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let(:document_chunk) do
    document.document_chunks.create!(account: account, assistant: assistant, chunk_index: 0, content: 'Refund policy source')
  end

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'Refund?', answer: 'Refund in 14 days', status: 'approved')
    translate_service = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    allow(translate_service).to receive(:translate).and_return('refund')
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: document_chunk.id))
  end

  it 'returns normalized faq matches payload' do
    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['query']).to eq('refund')
    expect(payload['total_count']).to eq(1)
    expect(payload['lookup_strategy']).to eq('semantic_chunk')
    expect(payload['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Refund policy source',
      'document_id' => document.id,
      'document_chunk_id' => document_chunk.id
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'semantic_chunk',
      'degraded' => false,
      'semantic_attempted' => true,
      'match_count' => 1,
      'response_ids' => [],
      'document_ids' => [document.id],
      'document_chunk_ids' => [document_chunk.id]
    )
  end

  it 'reranks semantic chunks and exposes rerank scores in the retrieval trace' do
    second_document = create(:captain_document, account: account, assistant: assistant)
    second_chunk = second_document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Warranty refund source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [document_chunk.id, second_chunk.id]))
    reranker = instance_double(Captain::Documents::Reranker)
    allow(Captain::Documents::Reranker).to receive(:new).with(account: account).and_return(reranker)
    allow(reranker).to receive(:call).and_return(
      Captain::Documents::Reranker::Result.new(
        documents: [second_chunk, document_chunk],
        trace: {
          attempted: true,
          enabled: true,
          degraded: false,
          model: 'cohere/rerank-v3.5',
          scores: [
            { document_chunk_id: second_chunk.id, relevance_score: 0.91 },
            { document_chunk_id: document_chunk.id, relevance_score: 0.31 }
          ]
        }
      )
    )

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['matches'].first).to include('document_chunk_id' => second_chunk.id, 'answer' => 'Warranty refund source')
    expect(payload['retrieval_trace']['rerank']).to include(
      'attempted' => true,
      'enabled' => true,
      'degraded' => false,
      'model' => 'cohere/rerank-v3.5'
    )
    expect(payload['retrieval_trace']['rerank']['scores']).to include(
      { 'document_chunk_id' => second_chunk.id, 'relevance_score' => 0.91 },
      { 'document_chunk_id' => document_chunk.id, 'relevance_score' => 0.31 }
    )
  end

  it 'falls back to keyword matches when semantic lookup is unavailable' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload).to include(
      'query' => 'refund',
      'translated_query' => 'refund',
      'total_count' => 1,
      'lookup_strategy' => 'lexical'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => true,
      'semantic_attempted' => true,
      'fallback_reason' => 'semantic_unavailable',
      'match_count' => 1
    )
    expect(payload).not_to have_key('error')
    expect(payload['matches'].first).to include(
      'question' => 'Refund?',
      'answer' => 'Refund in 14 days'
    )
  end

  it 'falls back to keyword matches when semantic lookup returns no matches' do
    document_chunk.update!(embedding_status: :indexed, embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1))
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.none)

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload).to include(
      'query' => 'refund',
      'translated_query' => 'refund',
      'total_count' => 1,
      'lookup_strategy' => 'lexical'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => true,
      'semantic_attempted' => true,
      'fallback_reason' => 'semantic_no_matches',
      'match_count' => 1
    )
    expect(payload).not_to have_key('error')
    expect(payload['matches'].first).to include(
      'question' => 'Refund?',
      'answer' => 'Refund in 14 days'
    )
  end

  it 'can skip translation and semantic lookup for realtime voice fallback' do
    expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
    expect(Captain::DocumentChunk).not_to receive(:search)

    payload = JSON.parse(service.execute(query: 'refund', semantic: false))

    expect(payload).to include(
      'query' => 'refund',
      'translated_query' => 'refund',
      'total_count' => 1,
      'lookup_strategy' => 'lexical'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => false,
      'semantic_attempted' => false,
      'match_count' => 1
    )
  end
end
