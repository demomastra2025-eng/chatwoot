require 'rails_helper'

RSpec.describe Captain::Tools::FaqLookupTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({}) }

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, question: 'How to reset password?', answer: 'Click forgot password',
                                        status: 'approved')
    allow(Captain::AssistantResponse).to receive(:search).and_return(Captain::AssistantResponse.where(assistant_id: assistant.id,
                                                                                                      account_id: account.id, status: :approved))
  end

  it 'returns normalized faq payload' do
    payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))

    expect(payload['query']).to eq('password reset')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include('question' => 'How to reset password?', 'answer' => 'Click forgot password')
  end

  it 'returns an empty faq payload when semantic lookup is unavailable' do
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'pricing'))

    expect(payload).to include(
      'query' => 'pricing',
      'total_count' => 0,
      'matches' => [],
      'error' => 'faq_lookup_unavailable'
    )
  end
end
