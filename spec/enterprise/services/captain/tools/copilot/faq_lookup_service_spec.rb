require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::FaqLookupService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, question: 'Refund?', answer: 'Refund in 14 days', status: 'approved')
    translate_service = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    allow(translate_service).to receive(:translate).and_return('refund')
    allow(Captain::AssistantResponse).to receive(:search).and_return(Captain::AssistantResponse.where(assistant_id: assistant.id,
                                                                                                      account_id: account.id, status: :approved))
  end

  it 'returns normalized faq matches payload' do
    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['query']).to eq('refund')
    expect(payload['total_count']).to eq(1)
    expect(payload['lookup_strategy']).to eq('semantic')
    expect(payload['matches'].first).to include(
      'question' => 'Refund?',
      'answer' => 'Refund in 14 days'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'semantic',
      'degraded' => false,
      'semantic_attempted' => true,
      'match_count' => 1,
      'response_ids' => [payload['matches'].first['id']]
    )
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

  it 'falls back to keyword matches when semantic lookup returns no matches' do
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
end
