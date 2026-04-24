require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddPrivateNoteService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
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
end
