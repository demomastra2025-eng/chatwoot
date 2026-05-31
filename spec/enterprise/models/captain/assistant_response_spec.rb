require 'rails_helper'

RSpec.describe Captain::AssistantResponse, type: :model do
  describe '.search' do
    let(:account) { create(:account) }

    it 'embeds semantic queries as search_query input' do
      embedding = Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1)
      embedding_service = instance_double(Captain::Llm::EmbeddingService)
      expect(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
      expect(embedding_service).to receive(:get_embedding)
        .with('shipping policy', input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
        .and_return(embedding)

      results = described_class.search('shipping policy', account_id: account.id)

      expect(results.to_sql).to include('captain_assistant_responses')
    end
  end

  describe 'edited tracking' do
    it 'does not mark a new response as edited' do
      response = create(:captain_assistant_response)

      expect(response.edited).to be false
    end

    it 'marks the response as edited when the question changes' do
      response = create(:captain_assistant_response)

      response.update!(question: 'Updated question?')

      expect(response.reload.edited).to be true
    end

    it 'marks the response as edited when the answer changes' do
      response = create(:captain_assistant_response)

      response.update!(answer: 'Updated answer')

      expect(response.reload.edited).to be true
    end
  end
end
