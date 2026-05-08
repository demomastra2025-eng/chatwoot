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
    expect(payload).not_to have_key('error')
    expect(payload['matches'].first).to include(
      'question' => 'Refund?',
      'answer' => 'Refund in 14 days'
    )
  end
end
