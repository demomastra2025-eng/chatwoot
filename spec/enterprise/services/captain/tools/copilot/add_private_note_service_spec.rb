require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddPrivateNoteService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized payload for the created private note' do
    payload = JSON.parse(service.execute(note: 'Нужно перезвонить'))

    message = conversation.messages.order(:id).last
    expect(payload).to include(
      'action' => 'add_private_note',
      'conversation_id' => conversation.id,
      'conversation_display_id' => conversation.display_id,
      'message_id' => message.id,
      'note' => 'Нужно перезвонить'
    )
  end

  it 'can add a note to a specified account conversation' do
    target_conversation = create(:conversation, account: account)

    payload = JSON.parse(service.execute(conversation_id: target_conversation.display_id, note: 'Follow up from search'))

    message = target_conversation.messages.order(:id).last
    expect(payload).to include(
      'action' => 'add_private_note',
      'conversation_id' => target_conversation.id,
      'conversation_display_id' => target_conversation.display_id,
      'message_id' => message.id,
      'note' => 'Follow up from search'
    )
    expect(conversation.messages).to be_empty
  end

  it 'does not add notes to another account conversation' do
    other_conversation = create(:conversation, account: create(:account))

    result = service.execute(conversation_id: other_conversation.id, note: 'Should not leak')

    expect(result).to include('Conversation not found')
    expect(other_conversation.messages).to be_empty
  end
end
