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
  let(:faq_response) do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'Refund?', answer: 'Refund in 14 days', status: 'approved')
  end

  before do
    faq_response
    translate_service = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    allow(translate_service).to receive(:translate).and_return('refund')
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    allow(Captain::AssistantResponse).to receive(:search).and_return(scored_response)
  end

  it 'returns normalized faq matches payload' do
    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['query']).to eq('refund')
    expect(payload['total_count']).to eq(1)
    expect(payload['lookup_strategy']).to eq('semantic_faq')
    expect(payload['matches'].first).to include(
      'type' => 'faq_response',
      'answer' => 'Refund in 14 days',
      'id' => faq_response.id,
      'document_chunk_id' => document_chunk.id,
      'score' => 0.9,
      'relevance_threshold' => 0.7,
      'relevance_threshold_passed' => true
    )
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

  it 'rejects a blank query before translation, cache, or semantic lookup' do
    expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
    expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
    expect(Captain::AssistantResponse).not_to receive(:search)

    expect(service.execute(query: '   ')).to eq('ERROR: query is required')
  end

  it 'does not expose a semantic candidate outside the relevance threshold' do
    translate_service = instance_double(Captain::Llm::TranslateQueryService, translate: 'irrelevantsemantic')
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    faq_response.define_singleton_method(:neighbor_distance) { 0.9 }
    allow(Captain::AssistantResponse).to receive(:search).and_return([faq_response])

    payload = JSON.parse(service.execute(query: 'irrelevant'))

    expect(payload).to include(
      'total_count' => 0,
      'result' => 'not_found',
      'message' => 'No relevant FAQ result found',
      'lookup_strategy' => 'semantic_faq'
    )
    expect(payload['matches']).to be_empty
    expect(payload['retrieval_trace']).to include(
      'degraded' => false,
      'no_match_reason' => 'relevance_threshold_not_met',
      'match_count' => 0
    )
    expect(payload.dig('retrieval_trace', 'relevance_check')).to include(
      'metric' => 'cosine_similarity',
      'threshold' => 0.7,
      'best_score' => 0.1,
      'candidate_count' => 1,
      'passed' => false
    )
  end

  it 'serves repeated translated semantic lookups from the answer cache' do
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    expect(Captain::AssistantResponse).to receive(:search).once.and_return(scored_response)

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

  it 'falls back to keyword matches when semantic lookup is unavailable' do
    allow(Captain::AssistantResponse).to receive(:search)
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
    allow(Captain::AssistantResponse).to receive(:search)
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
    allow(Captain::AssistantResponse).to receive(:search).and_raise(Timeout::Error, 'execution expired')

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

  it 'uses a total lookup budget around translation and semantic lookup' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::TOTAL_LOOKUP_TIMEOUT_SECONDS, described_class::TotalLookupTimeout)
      .and_raise(described_class::TotalLookupTimeout, 'execution expired')

    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'lookup_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Refund in 14 days')
  end

  it 'falls back to lexical document chunks when semantic lookup is unavailable' do
    chunk_only_document = create(:captain_document, account: account, assistant: assistant)
    chunk_only = chunk_only_document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Chunkonly refund source'
    )
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(service.execute(query: 'chunkonly'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(chunk_only.id)
    expect(payload['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Chunkonly refund source'
    )
  end

  it 'falls back to keyword matches when semantic lookup returns no matches' do
    faq_response.update!(embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1))
    allow(Captain::AssistantResponse).to receive(:search).and_return(Captain::AssistantResponse.none)

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
    expect(Captain::AssistantResponse).not_to receive(:search)

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

  it 'requests semantic FAQ results in the current assistant visibility scope' do
    other_assistant = create(:captain_assistant, account: account)
    general_response = create(
      :captain_assistant_response,
      account: account,
      assistant: other_assistant,
      visibility: :general,
      question: 'Shared workspace policy',
      answer: 'Shared workspace policy source'
    )
    expect(Captain::AssistantResponse).to receive(:search).with(
      'refund',
      account_id: account.id,
      assistant_id: assistant.id,
      limit: 5
    ).and_return(
      Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: general_response.id)
    )

    payload = JSON.parse(service.execute(query: 'workspace visibility'))

    expect(payload.dig('retrieval_trace', 'response_ids')).to contain_exactly(general_response.id)
    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared workspace policy source')
  end

  it 'returns an exact FAQ before translation, cache, and semantic lookup even when it has no embedding' do
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
    expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
    expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
    expect(Captain::AssistantResponse).not_to receive(:search)

    payload = JSON.parse(service.execute(query: 'Что такое ADAMANT CLUB?'))

    expect(payload['lookup_strategy']).to eq('lexical_exact')
    expect(payload['matches'].first).to include('id' => exact.id, 'answer' => 'Закрытый бизнес-клуб.')
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
