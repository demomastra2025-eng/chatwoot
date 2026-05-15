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
    confirmation_token = pending_gate.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}, отправляй" }
    )

    confirmed_payload = JSON.parse(service.execute(**arguments))

    expect(confirmed_payload['action']).to eq('send_message_to_conversation')
    expect(confirmed_payload.dig('message', 'content')).to eq('Hello from confirmed captain')
    expect(conversation.reload.messages.outgoing.last.content).to eq('Hello from confirmed captain')
    expect(pending_gate.reload.message.dig('confirmation_gate', 'status')).to eq('confirmed')
  end

  it 'requires a scoped confirmation token instead of ambient approval words' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
    arguments = { conversation_id: conversation.display_id, content: 'Do not send on generic ok' }

    JSON.parse(service.execute(**arguments))
    pending_gate = copilot_thread.copilot_messages.assistant_thinking.last

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => 'ok' }
    )

    second_payload = JSON.parse(service.execute(**arguments))

    expect(second_payload.dig('data', 'confirmation_required')).to be(true)
    expect(pending_gate.reload.message.dig('confirmation_gate', 'status')).to eq('pending')
    expect(conversation.reload.messages.outgoing.where(content: 'Do not send on generic ok')).to be_empty
  end

  it 'redacts sensitive arguments from confirmation previews while keeping the digest stable' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
    arguments = {
      conversation_id: conversation.display_id,
      content: 'Sensitive body',
      api_token: 'super-secret-token',
      nested: { password: 'hidden' }
    }

    payload = JSON.parse(service.execute(**arguments))
    preview = payload.dig('data', 'arguments_preview')

    expect(preview).to include('[FILTERED]')
    expect(preview).not_to include('super-secret-token')
    expect(preview).not_to include('hidden')
    expect(payload.dig('data', 'arguments_digest')).to be_present
  end

  it 'expires stale confirmation requests' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
    arguments = { conversation_id: conversation.display_id, content: 'Expired confirmation body' }

    JSON.parse(service.execute(**arguments))
    pending_gate = copilot_thread.copilot_messages.assistant_thinking.last
    message = pending_gate.message.deep_dup
    message['confirmation_gate']['requested_at'] = 31.minutes.ago.iso8601
    pending_gate.update!(message: message)

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{message['confirmation_gate']['confirmation_token']}" }
    )

    payload = JSON.parse(service.execute(**arguments))

    expect(payload.dig('data', 'confirmation_required')).to be(true)
    expect(pending_gate.reload.message.dig('confirmation_gate', 'status')).to eq('expired')
    expect(conversation.reload.messages.outgoing.where(content: 'Expired confirmation body')).to be_empty
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
