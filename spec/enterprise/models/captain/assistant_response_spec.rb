require 'rails_helper'

RSpec.describe Captain::AssistantResponse, type: :model do
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
