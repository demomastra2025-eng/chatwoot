require 'rails_helper'

# The side effects of an inbound native SIP event run under the caller's intake
# lock, in one transaction. Each step is a savepoint of its own: a step that
# fails undoes only itself, the steps before it stay and the ones after it are
# skipped, exactly as when every step committed on its own. The event ends
# "failed" so that it can be replayed.
RSpec.describe Telephony::EventsIngestionService, 'failure isolation of the side effects' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:call_ref) { "beeline:janus:isolation-#{SecureRandom.hex(4)}:call-id@sbc.example.test" }
  let!(:call_session) do
    create(
      :telephony_call_session,
      account: account, conversation: nil, contact: nil, inbox: inbox,
      provider: 'beeline', direction: 'inbound', status: 'ringing', external_call_ref: call_ref,
      from_number: '+70000000555', to_number: '+70000000099', metadata: { 'metadata' => { 'route_action' => 'operator' } }
    )
  end
  let(:payload) do
    { event_key: "evt-isolation-#{SecureRandom.hex(3)}", account_id: account.id, call_ref: call_ref, provider: 'beeline',
      event: 'operator_no_answer', event_type: 'operator_no_answer', status: 'no_answer', direction: 'inbound' }
  end

  # A call that is still ringing: the plain path of the side effects.
  let(:ringing_payload) do
    payload.merge(event_key: "evt-ringing-#{SecureRandom.hex(3)}", event: 'ringing', event_type: 'ringing', status: 'ringing')
  end

  def chat_state
    {
      conversations: account.conversations.count,
      session_conversation: call_session.reload.conversation_id.present?,
      voice_messages: account.messages.voice_calls.count,
      events: account.telephony_events.pluck(:status)
    }
  end

  it 'gives the call its conversation and its voice message when nothing fails' do
    described_class.new(payload: payload).perform

    expect(chat_state).to eq(conversations: 1, session_conversation: true, voice_messages: 1, events: ['processed'])
  end

  it 'keeps the call in the chat when the last optional step fails' do
    allow_any_instance_of(described_class).to receive(:collapse_terminal_native_sip_handoff!).and_raise(StandardError, 'simulated failure')

    described_class.new(payload: payload).perform

    expect(chat_state).to eq(conversations: 1, session_conversation: true, voice_messages: 1, events: ['failed'])
  end

  it 'keeps the steps before a failing step and skips the steps after it' do
    allow_any_instance_of(described_class).to receive(:apply_call_status!).and_raise(StandardError, 'simulated failure')
    synced = false
    allow_any_instance_of(described_class).to receive(:sync_voice_message!) { synced = true }

    described_class.new(payload: ringing_payload).perform

    expect(chat_state).to include(conversations: 1, session_conversation: true, events: ['failed'])
    expect(synced).to be(false)
  end

  it 'undoes what a failing step wrote itself' do
    allow_any_instance_of(described_class).to receive(:sync_voice_message!) do
      account.conversations.first.update!(additional_attributes: { 'call_status' => 'half_written' })
      raise StandardError, 'simulated failure'
    end

    described_class.new(payload: ringing_payload).perform

    expect(account.conversations.first.additional_attributes['call_status']).not_to eq('half_written')
    expect(account.telephony_events.pluck(:status)).to eq(['failed'])
  end
end
