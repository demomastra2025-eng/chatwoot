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

  it 'blocks confirmation-required assistant tools until the operator confirms the same arguments', :aggregate_failures do
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

    replay_payload = JSON.parse(service.execute(**arguments))

    expect(replay_payload.dig('data', 'confirmation_required')).to be(true)
    expect(conversation.reload.messages.outgoing.where(content: 'Hello from confirmed captain').count).to eq(1)
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

  it 'accepts an explicit confirmation without a token when exactly one action is pending' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: copilot_thread
    )
    arguments = { conversation_id: conversation.display_id, content: 'Send after unambiguous confirmation' }

    JSON.parse(service.execute(**arguments))
    pending_gate = copilot_thread.copilot_messages.assistant_thinking.last
    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => 'Подтверждаю, отправляй' }
    )

    confirmed_payload = JSON.parse(service.execute(**arguments))

    expect(confirmed_payload['action']).to eq('send_message_to_conversation')
    expect(pending_gate.reload.message.dig('confirmation_gate', 'status')).to eq('confirmed')
    expect(conversation.reload.messages.outgoing.last.content).to eq('Send after unambiguous confirmation')
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

  it 'redacts sensitive values inside JSON string arguments in confirmation previews' do
    service = Captain::Tools::Copilot::CreateAutomationRuleService.new(
      assistant,
      user: user,
      copilot_thread: copilot_thread
    )
    actions_json = [{ action_name: 'send_webhook_event', action_params: ['https://secret.example/webhook?token=abc'] }].to_json

    payload = JSON.parse(service.execute(name: 'Webhook rule', event_name: 'conversation_created', actions_json: actions_json))
    preview = payload.dig('data', 'arguments_preview')

    expect(preview).to include('[FILTERED]')
    expect(preview).not_to include('secret.example')
    expect(preview).not_to include('token=abc')
    expect(payload.dig('data', 'arguments_digest')).to be_present
  end

  it 'redacts secret-like instruction values from confirmation previews' do
    service = Captain::Tools::Copilot::CreateCaptainScenarioService.new(
      assistant,
      user: user,
      copilot_thread: copilot_thread
    )

    payload = JSON.parse(
      service.execute(
        assistant_id: assistant.id,
        title: 'Sensitive Scenario',
        description: 'Preview should be redacted',
        instruction: 'Use session=abc, password: p4ss, authorization: Basic aaa and webhook_secret=xyz'
      )
    )
    preview = payload.dig('data', 'arguments_preview')

    expect(preview).to include('[FILTERED]')
    expect(preview).not_to include('session=abc')
    expect(preview).not_to include('password: p4ss')
    expect(preview).not_to include('authorization: Basic aaa')
    expect(preview).not_to include('webhook_secret=xyz')
    expect(Captain::Scenario.where(account: account, title: 'Sensitive Scenario')).not_to exist
  end

  it 'redacts document-source arguments in confirmation previews' do
    gate = described_class.new(
      copilot_thread: copilot_thread,
      tool_definition: {
        id: 'create_captain_knowledge_document',
        title: 'Create Captain Knowledge Document',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: {
        assistant_id: assistant.id,
        name: 'Docs',
        external_link: 'https://docs.example.test/page?token=abc',
        source_text: 'Raw source text should not persist',
        artifact_id: 'signed-artifact-id',
        import_profile_json: { metadata: 'internal metadata', content: 'hidden content' }.to_json
      },
      user: user
    )

    payload = JSON.parse(gate.call)
    preview = payload.dig('data', 'arguments_preview')
    pending_preview = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'arguments_preview')

    expect(preview).to include('[FILTERED]')
    expect(preview).not_to include('docs.example.test')
    expect(preview).not_to include('Raw source text')
    expect(preview).not_to include('signed-artifact-id')
    expect(preview).not_to include('internal metadata')
    expect(pending_preview).not_to include('hidden content')
  end

  it 'redacts knowledge-entry question and answer arguments in confirmation previews' do
    gate = described_class.new(
      copilot_thread: copilot_thread,
      tool_definition: {
        id: 'create_captain_knowledge_entry',
        title: 'Create Captain Knowledge Entry',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: {
        assistant_id: assistant.id,
        question: 'How do I pay?',
        answer: 'Use the invoice portal.',
        status: 'approved'
      },
      user: user
    )

    payload = JSON.parse(gate.call)
    preview = payload.dig('data', 'arguments_preview')
    pending_preview = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'arguments_preview')

    expect(preview).to include('[FILTERED]')
    expect(preview).not_to include('How do I pay?')
    expect(preview).not_to include('Use the invoice portal.')
    expect(pending_preview).not_to include('Use the invoice portal.')
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

  it 'blocks confirmation-required tools when no copilot thread can store the request' do
    service = Captain::Tools::Copilot::SendMessageToConversationService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: nil
    )

    payload = JSON.parse(service.execute(conversation_id: conversation.display_id, content: 'No thread send'))

    expect(payload.dig('data', 'confirmation_required')).to be(true)
    expect(payload.dig('data', 'confirmation_unavailable')).to be(true)
    expect(conversation.reload.messages.outgoing.where(content: 'No thread send')).to be_empty
  end

  it 'blocks high-risk built-in assistant tools without an explicit registry confirmation flag' do
    account.enable_features!('crm_deals')
    service = Captain::Tools::Copilot::CreateDealService.new(
      assistant,
      user: user,
      conversation: conversation,
      copilot_thread: nil
    )

    payload = JSON.parse(service.execute(title: 'Unconfirmed deal'))

    expect(payload.dig('data', 'confirmation_required')).to be(true)
    expect(payload.dig('data', 'confirmation_unavailable')).to be(true)
    expect(account.crm_deals.where(title: 'Unconfirmed deal')).to be_empty
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
