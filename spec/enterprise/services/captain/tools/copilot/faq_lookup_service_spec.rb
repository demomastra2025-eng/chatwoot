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

  it 'serves repeated translated semantic lookups from the answer cache' do
    expect(Captain::DocumentChunk).to receive(:search).once.and_return(Captain::DocumentChunk.where(id: document_chunk.id))

    first_payload = JSON.parse(service.execute(query: 'возврат'))
    second_payload = JSON.parse(service.execute(query: 'вернуть деньги'))

    expect(first_payload.dig('retrieval_trace', 'answer_cache')).to include('hit' => false, 'stored' => true)
    expect(second_payload).to include('query' => 'вернуть деньги', 'translated_query' => 'refund')
    expect(second_payload.dig('retrieval_trace', 'answer_cache')).to include(
      'enabled' => true,
      'hit' => true,
      'match' => 'exact',
      'hit_count' => 1
    )
    expect(second_payload['matches'].first).to include('document_chunk_id' => document_chunk.id)
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

  it 'marks semantic lookup as not configured when embeddings are not configured' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'OpenRouter embeddings are not configured.')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_not_configured',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Refund in 14 days')
  end

  it 'degrades to keyword matches when semantic lookup times out' do
    allow(Captain::DocumentChunk).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Refund in 14 days')
  end

  it 'bounds semantic lookup and returns lexical results when the timeout fires' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::SEMANTIC_LOOKUP_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Refund in 14 days')
  end

  it 'bounds answer-cache reads and returns lexical results when cache lookup times out' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::CACHE_FETCH_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Refund in 14 days')
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

  it 'shares general chunks but hides another assistant personal chunks from semantic lookup' do
    other_assistant = create(:captain_assistant, account: account)
    general_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :general)
    personal_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :personal)
    general_chunk = general_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Shared workspace policy source'
    )
    personal_chunk = personal_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Private assistant policy source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [general_chunk.id, personal_chunk.id]))

    payload = JSON.parse(service.execute(query: 'workspace visibility'))

    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(general_chunk.id)
    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared workspace policy source')
  end

  it 'shares general FAQ entries but hides another assistant personal entries from lexical lookup' do
    other_assistant = create(:captain_assistant, account: account)
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope shared',
      answer: 'Shared workspace answer',
      visibility: :general,
      status: :approved
    )
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope private',
      answer: 'Private assistant answer',
      visibility: :personal,
      status: :approved
    )

    payload = JSON.parse(service.execute(query: 'visibilityscope', semantic: false))

    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared workspace answer')
  end
end
