require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseCancellationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, status: :pending) }
  let!(:incoming) { create(:message, conversation: conversation, message_type: :incoming) }
  let(:service) { described_class.new(conversation: conversation, assistant: assistant) }
  let(:state_key) { format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id) }
  let(:buffer_key) { format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id) }

  before { allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off) }

  after do
    Redis::Alfred.delete(state_key)
    Redis::Alfred.delete(buffer_key)
  end

  it 'captures the run generation and status epoch before publishing cancellation' do
    snapshot = service.snapshot
    expect(Redis::Alfred.get(state_key)).to be_nil
    expect(snapshot).to include(
      account_id: account.id, conversation_id: conversation.id, assistant_id: assistant.id,
      control_generation: 0, status_transition_id: 0, last_message_id: incoming.id
    )
    expect(service.perform(snapshot: snapshot)).to be true
  end

  it 'does not cancel a new generation or status epoch with the same incoming message' do
    service.perform
    expect(service.cancelled?(expected_last_message_id: incoming.id, expected_control_generation: 0, expected_status_transition_id: 0)).to be true
    expect(service.cancelled?(expected_last_message_id: incoming.id, expected_control_generation: 1, expected_status_transition_id: 0)).to be false
    expect(service.cancelled?(expected_last_message_id: incoming.id, expected_control_generation: 0, expected_status_transition_id: 1)).to be false
  end

  it 'captures a buffered run by token and message rather than cancelling a newer buffer' do
    Redis::Alfred.set(buffer_key, { token: 'old', last_message_id: incoming.id, control_generation: 0, assistant_id: assistant.id }.to_json, ex: 60)
    snapshot = service.snapshot
    Redis::Alfred.set(buffer_key, { token: 'new', last_message_id: incoming.id, control_generation: 1, assistant_id: assistant.id }.to_json, ex: 60)
    service.perform(snapshot: snapshot)

    expect(service.cancelled?(buffer_token: 'old', expected_last_message_id: incoming.id, expected_control_generation: 0)).to be true
    expect(service.cancelled?(buffer_token: 'new', expected_last_message_id: incoming.id, expected_control_generation: 1)).to be false
    expect(JSON.parse(Redis::Alfred.get(buffer_key))['token']).to eq('new')
  end

  it 'does not overwrite a newer cancellation with a delayed takeover snapshot' do
    old_snapshot = service.snapshot
    travel 1.second do
      service.perform(reason: 'newer manager cancellation')
    end

    expect(service.perform(snapshot: old_snapshot)).to be false
    expect(JSON.parse(Redis::Alfred.get(state_key))['cancel_reason']).to eq('newer manager cancellation')
  end

  it 'does not clear a replacement cancellation installed after reading the old one' do
    service.perform
    replacement = service.snapshot.merge(cancel_reason: 'replacement').to_json
    allow(Redis::Alfred).to receive(:delete_if_value).and_wrap_original do |method, key, value|
      Redis::Alfred.set(key, replacement, ex: 60)
      method.call(key, value)
    end

    expect(service.clear_if_current!(expected_last_message_id: incoming.id)).to be false
    expect(Redis::Alfred.get(state_key)).to eq(replacement)
  end

  it 'rejects a snapshot for another account, conversation or assistant' do
    snapshot = service.snapshot
    %i[account_id conversation_id assistant_id].each do |key|
      expect(service.perform(snapshot: snapshot.merge(key => snapshot.fetch(key) + 1))).to be false
    end
    expect(Redis::Alfred.get(state_key)).to be_nil
  end

  it 'rejects an assistant from another account' do
    foreign_assistant = create(:captain_assistant)
    foreign_service = described_class.new(conversation: conversation, assistant: foreign_assistant)
    expect(foreign_service.perform).to be false
    expect(Redis::Alfred.get(state_key)).to be_nil
  end
end
