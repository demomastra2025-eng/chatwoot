require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdatePriorityService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, priority: nil) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized payload with updated priority' do
    payload = JSON.parse(service.execute(priority: 'high'))

    expect(payload).to include(
      'action' => 'update_priority',
      'conversation_id' => conversation.id,
      'conversation_display_id' => conversation.display_id,
      'priority' => 'high'
    )
  end
end
