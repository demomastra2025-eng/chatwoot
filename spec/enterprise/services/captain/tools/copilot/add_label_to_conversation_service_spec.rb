require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddLabelToConversationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    create(:label, account: account, title: 'sales')
  end

  it 'returns a normalized payload with labels after adding one' do
    payload = JSON.parse(service.execute(label_name: 'sales'))

    expect(payload).to include(
      'action' => 'add_label_to_conversation',
      'conversation_id' => conversation.id,
      'conversation_display_id' => conversation.display_id,
      'label_name' => 'sales'
    )
    expect(payload['labels']).to include('sales')
  end
end
