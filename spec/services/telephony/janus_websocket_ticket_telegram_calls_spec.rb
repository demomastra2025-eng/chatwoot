require 'rails_helper'

RSpec.describe Telephony::JanusWebsocketTicket do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:channel) { create(:channel_telegram_personal, account: account, connection_state: 'connected') }
  let(:offer) do
    { 'transport' => 'janus_audiobridge', 'room_id' => 450_001, 'pin' => 'room-pin', 'token' => 'browser-token', 'peer_id' => 'generation-1' }
  end
  let(:call) do
    create(:call, account: account, provider: :telegram_personal, inbox: channel.inbox,
                  status: 'in_progress', accepted_by_agent: user, meta: { 'agent_offer' => offer })
  end
  let(:ticket) do
    described_class.issue_for_telegram_call(server_url: 'wss://app.example.test/janus-sipuni', account: account, user: user, call: call, offer: offer)
  end

  def valid_ticket?(value = ticket)
    described_class.valid?(ticket: value, origin: 'https://app.example.test', path: '/janus-sipuni')
  end

  it 'authorizes only one use and does not require a SIP registration' do
    expect(valid_ticket?).to be(true)
    expect(described_class.authorize?(ticket: ticket, origin: 'https://app.example.test', path: '/janus-sipuni')).to be(true)
    expect(described_class.authorize?(ticket: ticket, origin: 'https://app.example.test', path: '/janus-sipuni')).to be(false)
  end

  it 'does not put room access credentials in the signed ticket' do
    payload = described_class.send(:verified_payload, ticket)
    expect(payload).to include('call_id' => call.id, 'room_id' => offer['room_id'], 'peer_id' => offer['peer_id'])
    expect(payload.keys).not_to include('pin', 'token', 'secret', 'admin_key')
  end

  it 'rejects a different account at issue time' do
    expect do
      described_class.issue_for_telegram_call(server_url: 'wss://app.example.test/janus-sipuni', account: create(:account),
                                              user: user, call: call, offer: offer)
    end.to raise_error(ArgumentError)
  end

  it 'refuses to issue a ticket to a different operator' do
    other = create(:user, account: account, role: :administrator)
    expect do
      described_class.issue_for_telegram_call(server_url: 'wss://app.example.test/janus-sipuni', account: account,
                                              user: other, call: call, offer: offer)
    end.to raise_error(ArgumentError)
  end

  it 'revokes tickets when the call ends' do
    issued = ticket
    call.update!(status: 'completed')
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes tickets when ownership changes' do
    issued = ticket
    call.update!(accepted_by_agent: create(:user, account: account, role: :administrator))
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes tickets when the media session changes' do
    issued = ticket
    call.update!(media_session_id: 'replacement-session')
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes tickets when a reconnect changes room generation' do
    issued = ticket
    call.update!(meta: { 'agent_offer' => offer.merge('peer_id' => 'generation-2') })
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes tickets when account membership is removed' do
    issued = ticket
    AccountUser.find_by!(account_id: account.id, user_id: user.id).destroy!
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'continues to enforce origin and endpoint binding' do
    expect(described_class.valid?(ticket: ticket, origin: 'https://other.example.test', path: '/janus-sipuni')).to be(false)
    expect(described_class.valid?(ticket: ticket, origin: 'https://app.example.test', path: '/janus-asterisk')).to be(false)
  end

  it 'continues to reject a missing Origin for TelegramPersonal version2' do
    expect(described_class.valid?(ticket: ticket, origin: nil, path: '/janus-sipuni')).to be(false)
    expect(described_class.valid?(ticket: ticket, origin: '', path: '/janus-sipuni')).to be(false)
    expect(valid_ticket?).to be(true)
  end
end
