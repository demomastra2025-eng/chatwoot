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

  describe 'workspace ownership' do
    let(:account) { create(:account) }

    it 'allows general workspace entries without an assistant' do
      response = build(:captain_assistant_response, account: account, assistant: nil, visibility: :general)

      expect(response).to be_valid
    end

    it 'allows workspace-personal entries without an assistant' do
      response = build(:captain_assistant_response, account: account, assistant: nil, visibility: :personal)

      expect(response).to be_valid
    end

    it 'inherits account ownership from the attached document when assistant is blank' do
      document = create(:captain_document, account: account, assistant: nil, visibility: :general)
      response = build(:captain_assistant_response, account: nil, assistant: nil, documentable: document)

      expect(response).to be_valid
      expect(response.account).to eq(account)
    end

    it 'returns general entries plus personal entries for the selected assistant' do
      general_response = create(:captain_assistant_response, account: account, assistant: nil, visibility: :general)
      workspace_personal_response = create(:captain_assistant_response, account: account, assistant: nil, visibility: :personal)
      personal_response = create(
        :captain_assistant_response,
        account: account,
        assistant: create(:captain_assistant, account: account),
        visibility: :personal
      )
      other_personal_response = create(
        :captain_assistant_response,
        account: account,
        assistant: create(:captain_assistant, account: account),
        visibility: :personal
      )

      expect(described_class.visible_to_assistant(personal_response.assistant_id)).to include(
        general_response,
        workspace_personal_response,
        personal_response
      )
      expect(described_class.visible_to_assistant(personal_response.assistant_id)).not_to include(other_personal_response)
    end

    it 'returns workspace-owned entries without an assistant filter' do
      general_response = create(:captain_assistant_response, account: account, assistant: nil, visibility: :general)
      workspace_personal_response = create(:captain_assistant_response, account: account, assistant: nil, visibility: :personal)
      assistant_personal_response = create(
        :captain_assistant_response,
        account: account,
        assistant: create(:captain_assistant, account: account),
        visibility: :personal
      )

      expect(described_class.visible_to_assistant(nil)).to include(general_response, workspace_personal_response)
      expect(described_class.visible_to_assistant(nil)).not_to include(assistant_personal_response)
    end
  end
end
