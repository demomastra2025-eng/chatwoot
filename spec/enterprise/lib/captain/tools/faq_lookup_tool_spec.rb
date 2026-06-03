require 'rails_helper'

RSpec.describe Captain::Tools::FaqLookupTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({}) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let(:document_chunk) do
    document.document_chunks.create!(account: account, assistant: assistant, chunk_index: 0, content: 'Password reset source')
  end

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'How to reset password?', answer: 'Click forgot password', status: 'approved')
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: document_chunk.id))
  end

  it 'returns normalized faq payload' do
    payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))

    expect(payload['query']).to eq('password reset')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include('type' => 'document_chunk', 'answer' => 'Password reset source')
    expect(payload['matches'].first).to include('document_id' => document.id, 'document_chunk_id' => document_chunk.id)
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

  it 'serves repeated semantic lookups from the answer cache' do
    expect(Captain::DocumentChunk).to receive(:search).once.and_return(Captain::DocumentChunk.where(id: document_chunk.id))

    first_payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))
    second_payload = JSON.parse(tool.perform(tool_context, query: ' password   reset '))

    expect(first_payload.dig('retrieval_trace', 'answer_cache')).to include('hit' => false, 'stored' => true)
    expect(second_payload.dig('retrieval_trace', 'answer_cache')).to include(
      'enabled' => true,
      'hit' => true,
      'match' => 'exact',
      'hit_count' => 1
    )
    expect(second_payload['query']).to eq(' password   reset ')
    expect(second_payload['matches'].first).to include('document_chunk_id' => document_chunk.id)
  end

  it 'reranks semantic chunks and exposes rerank scores in the retrieval trace' do
    second_document = create(:captain_document, account: account, assistant: assistant)
    second_chunk = second_document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Account recovery source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [document_chunk.id, second_chunk.id]))
    reranker = instance_double(Captain::Documents::Reranker)
    allow(Captain::Documents::Reranker).to receive(:new).with(account: account).and_return(reranker)
    allow(reranker).to receive(:call) do |query:, documents:, top_n:|
      expect(query).to eq('password reset')
      expect(documents).to contain_exactly(document_chunk, second_chunk)
      expect(top_n).to eq(5)
      Captain::Documents::Reranker::Result.new(
        documents: [second_chunk, document_chunk],
        trace: {
          attempted: true,
          enabled: true,
          degraded: false,
          model: 'cohere/rerank-v3.5',
          scores: [
            { document_chunk_id: second_chunk.id, relevance_score: 0.96 },
            { document_chunk_id: document_chunk.id, relevance_score: 0.42 }
          ]
        }
      )
    end

    payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))

    expect(payload['matches'].first).to include('document_chunk_id' => second_chunk.id, 'answer' => 'Account recovery source')
    expect(payload['retrieval_trace']['rerank']).to include(
      'attempted' => true,
      'enabled' => true,
      'degraded' => false,
      'model' => 'cohere/rerank-v3.5'
    )
    expect(payload['retrieval_trace']['rerank']['scores']).to include(
      { 'document_chunk_id' => second_chunk.id, 'relevance_score' => 0.96 },
      { 'document_chunk_id' => document_chunk.id, 'relevance_score' => 0.42 }
    )
  end

  it 'falls back to exact/keyword FAQ lookup when semantic lookup is unavailable' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload).to include(
      'query' => 'reset password',
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
      'question' => 'How to reset password?',
      'answer' => 'Click forgot password'
    )
  end

  it 'returns an empty lexical payload when embeddings are unavailable and no keyword matches' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'pricing'))

    expect(payload).to include(
      'query' => 'pricing',
      'total_count' => 0,
      'matches' => [],
      'lookup_strategy' => 'lexical'
    )
    expect(payload).not_to have_key('error')
  end

  it 'marks semantic lookup as not configured when embeddings are not configured' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'OpenRouter embeddings are not configured.')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_not_configured',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'degrades to lexical lookup when semantic lookup times out' do
    allow(Captain::DocumentChunk).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'bounds semantic lookup and returns lexical results when the timeout fires' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::SEMANTIC_LOOKUP_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'bounds answer-cache reads and returns lexical results when cache lookup times out' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::CACHE_FETCH_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'can skip semantic lookup for realtime voice calls' do
    expect(Captain::DocumentChunk).not_to receive(:search)

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password', semantic: false))

    expect(payload).to include(
      'query' => 'reset password',
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

  it 'shares general chunks but hides another assistant personal chunks' do
    other_assistant = create(:captain_assistant, account: account)
    general_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :general)
    personal_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :personal)
    general_chunk = general_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Shared account recovery source'
    )
    personal_chunk = personal_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Private account recovery source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [general_chunk.id, personal_chunk.id]))

    payload = JSON.parse(tool.perform(tool_context, query: 'account recovery'))

    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(general_chunk.id)
    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared account recovery source')
  end
end
