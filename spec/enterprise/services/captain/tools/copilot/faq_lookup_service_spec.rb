require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::FaqLookupService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, question: 'Refund?', answer: 'Refund in 14 days', status: 'approved')
    allow(Captain::Llm::TranslateQueryService).to receive_message_chain(:new, :translate).and_return('refund')
    allow(Captain::AssistantResponse).to receive(:search).and_return(Captain::AssistantResponse.where(assistant_id: assistant.id,
                                                                                                      account_id: account.id, status: :approved))
  end

  it 'returns normalized faq matches payload' do
    payload = JSON.parse(service.execute(query: 'refund'))

    expect(payload['query']).to eq('refund')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include(
      'question' => 'Refund?',
      'answer' => 'Refund in 14 days'
    )
  end
end
