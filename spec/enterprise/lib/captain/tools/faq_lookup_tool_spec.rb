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
  let(:faq_response) do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'How to reset password?', answer: 'Click forgot password', status: 'approved')
  end

  before do
    faq_response
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    allow(Captain::AssistantResponse).to receive(:search).and_return(scored_response)
  end

  it 'returns normalized faq payload' do
    payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))

    expect(payload['query']).to eq('password reset')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include('type' => 'faq_response', 'answer' => 'Click forgot password')
    expect(payload['matches'].first).to include('id' => faq_response.id, 'document_chunk_id' => document_chunk.id)
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'semantic_faq',
      'degraded' => false,
      'semantic_attempted' => true,
      'match_count' => 1,
      'response_ids' => [faq_response.id],
      'document_ids' => [document.id],
      'document_chunk_ids' => [document_chunk.id]
    )
  end

  it 'serves repeated semantic lookups from the answer cache' do
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    expect(Captain::AssistantResponse).to receive(:search).once.and_return(scored_response)

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

  it 'does not expose a semantic candidate outside the relevance threshold' do
    faq_response.define_singleton_method(:neighbor_distance) { 0.9 }
    allow(Captain::AssistantResponse).to receive(:search).and_return([faq_response])

    payload = JSON.parse(tool.perform(tool_context, query: 'unrelated phrase'))

    expect(payload).to include('total_count' => 0, 'lookup_strategy' => 'lexical')
    expect(payload['matches']).to be_empty
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_no_matches',
      'match_count' => 0
    )
  end

  it 'falls back to exact/keyword FAQ lookup when semantic lookup is unavailable' do
    allow(Captain::AssistantResponse).to receive(:search)
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
    allow(Captain::AssistantResponse).to receive(:search)
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
    allow(Captain::AssistantResponse).to receive(:search)
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
    allow(Captain::AssistantResponse).to receive(:search).and_raise(Timeout::Error, 'execution expired')

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

  it 'uses a total lookup budget around cache and semantic lookup' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::TOTAL_LOOKUP_TIMEOUT_SECONDS, described_class::TotalLookupTimeout)
      .and_raise(described_class::TotalLookupTimeout, 'execution expired')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'lookup_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'falls back to lexical document chunks when semantic lookup is unavailable' do
    chunk_only_document = create(:captain_document, account: account, assistant: assistant)
    chunk_only = chunk_only_document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Chunkonly recovery source'
    )
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'chunkonly'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(chunk_only.id)
    expect(payload['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Chunkonly recovery source'
    )
  end

  it 'can skip semantic lookup for realtime voice calls' do
    expect(Captain::AssistantResponse).not_to receive(:search)

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

  it 'requests semantic FAQ results in the current assistant visibility scope' do
    other_assistant = create(:captain_assistant, account: account)
    general_response = create(
      :captain_assistant_response,
      account: account,
      assistant: other_assistant,
      visibility: :general,
      question: 'Shared account recovery',
      answer: 'Shared account recovery source'
    )
    expect(Captain::AssistantResponse).to receive(:search).with(
      'account recovery',
      account_id: account.id,
      assistant_id: assistant.id,
      limit: 5
    ).and_return(Captain::AssistantResponse.where(id: general_response.id))

    payload = JSON.parse(tool.perform(tool_context, query: 'account recovery'))

    expect(payload.dig('retrieval_trace', 'response_ids')).to contain_exactly(general_response.id)
    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared account recovery source')
  end

  it 'returns an exact FAQ before cache and semantic lookup even when it has no embedding' do
    allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later)
    exact = create(
      :captain_assistant_response,
      account: account,
      assistant: nil,
      question: 'Что такое ADAMANT CLUB?',
      answer: 'Закрытый бизнес-клуб.',
      embedding: nil,
      created_at: 1.day.ago
    )
    expect(exact.embedding).to be_nil
    create(
      :captain_assistant_response,
      account: account,
      assistant: nil,
      question: 'Кто основатель клуба?',
      answer: 'Основатель ADAMANT CLUB.',
      embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1),
      created_at: Time.current
    )
    expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
    expect(Captain::AssistantResponse).not_to receive(:search)

    payload = JSON.parse(tool.perform(tool_context, query: 'Что такое ADAMANT CLUB?'))

    expect(payload['lookup_strategy']).to eq('lexical_exact')
    expect(payload['matches'].first).to include('id' => exact.id, 'answer' => 'Закрытый бизнес-клуб.')
  end
end
