require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::HandoffService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, status: 'open') }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized payload for handoff' do
    freeze_time do
      payload = JSON.parse(service.execute(reason: 'сложный кейс'))

      expect(payload).to include(
        'action' => 'handoff',
        'conversation_id' => conversation.id,
        'conversation_display_id' => conversation.display_id,
        'reason' => 'сложный кейс'
      )
      expect(payload['waiting_since']).to eq(Time.current.iso8601)
    end
  end
end
