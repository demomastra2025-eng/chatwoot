require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddLabelToConversationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
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

  it 'can label a specified account conversation' do
    target_conversation = create(:conversation, account: account)

    payload = JSON.parse(service.execute(conversation_id: target_conversation.display_id, label_name: 'sales'))

    expect(payload).to include(
      'action' => 'add_label_to_conversation',
      'conversation_id' => target_conversation.id,
      'conversation_display_id' => target_conversation.display_id,
      'label_name' => 'sales'
    )
    expect(target_conversation.reload.label_list).to include('sales')
    expect(conversation.reload.label_list).to be_empty
  end
end
