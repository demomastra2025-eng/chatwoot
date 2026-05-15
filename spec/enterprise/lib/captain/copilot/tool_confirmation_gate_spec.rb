# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Copilot::ToolConfirmationGate do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }

  it 'blocks confirmation-required assistant tools until the operator confirms the same arguments' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
    arguments = { conversation_id: conversation.display_id, content: 'Hello from confirmed captain' }

    first_payload = JSON.parse(service.execute(**arguments))

    expect(first_payload['data']).to include(
      'action' => 'confirmation_required',
      'confirmation_required' => true,
      'tool_id' => 'send_message_to_conversation'
    )
    expect(conversation.reload.messages.outgoing.where(content: 'Hello from confirmed captain')).to be_empty

    pending_gate = copilot_thread.copilot_messages.assistant_thinking.last
    expect(pending_gate.message.dig('confirmation_gate', 'status')).to eq('pending')
    expect(pending_gate.message.dig('confirmation_gate', 'tool_id')).to eq('send_message_to_conversation')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => 'Подтверждаю, отправляй' }
    )

    confirmed_payload = JSON.parse(service.execute(**arguments))

    expect(confirmed_payload['action']).to eq('send_message_to_conversation')
    expect(confirmed_payload.dig('message', 'content')).to eq('Hello from confirmed captain')
    expect(conversation.reload.messages.outgoing.last.content).to eq('Hello from confirmed captain')
    expect(pending_gate.reload.message.dig('confirmation_gate', 'status')).to eq('confirmed')
  end

  it 'does not gate non-confirmation tools' do
    service = Captain::Tools::Copilot::SearchContactsService.new(
      assistant,
      user: user,
      copilot_thread: copilot_thread
    )
    create(:contact, account: account, name: 'Aida Safe')

    payload = JSON.parse(service.execute(name: 'Aida'))

    expect(payload['contacts'].first['name']).to eq('Aida Safe')
    expect(copilot_thread.copilot_messages.assistant_thinking).to be_empty
  end
end
