require 'rails_helper'

RSpec.describe TelegramPersonal::JanusMediaConfig do
  let(:offer) do
    { 'transport' => 'janus_audiobridge', 'room_id' => 45_001, 'pin' => 'room-pin', 'token' => 'browser-token', 'peer_id' => 'generation-1' }
  end
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:channel) { create(:channel_telegram_personal, account: account, connection_state: 'connected') }
  let(:call) do
    create(:call, account: account, provider: :telegram_personal, inbox: channel.inbox,
                  status: 'in_progress', accepted_by_agent: user, meta: { 'agent_offer' => offer })
  end

  describe '.normalize' do
    it 'keeps only browser room credentials, never a gateway-provided server or admin credentials' do
      input = offer.merge('server' => 'wss://untrusted.test', 'secret' => 'admin-secret', 'admin_key' => 'admin-key')
      expect(described_class.normalize(input)).to eq(offer)
    end

    it 'refuses the previous direct SDP transport' do
      expect(described_class.normalize(peer_id: 'old-peer', sdp_offer: 'v=0')).to be_nil
      expect { described_class.normalize!(peer_id: 'old-peer', sdp_offer: 'v=0') }.to raise_error(described_class::InvalidConfig)
    end

    [0, -1, 2**53, 1.5, '45001', nil].each do |room_id|
      it "rejects invalid or unsafe room ID #{room_id.inspect}" do
        expect(described_class.normalize(offer.merge('room_id' => room_id))).to be_nil
      end
    end

    %w[pin token peer_id].each do |key|
      it "requires a nonempty #{key}" do
        expect(described_class.normalize(offer.except(key))).to be_nil
      end
    end
  end

  describe '.browser_payload' do
    around do |example|
      with_modified_env('TELEPHONY_JANUS_WS_URL' => nil, 'JANUS_PUBLIC_WS_URL' => nil,
                        'FRONTEND_URL' => 'https://app.example.test',
                        'TELEPHONY_JANUS_ICE_SERVERS_JSON' => '[{"urls":["stun:stun.example.test:3478"]}]') { example.run }
    end

    it 'uses the shared Janus endpoint and authorizes a Telegram-only operator without a SIP profile' do
      payload = described_class.browser_payload(call: call, user: user)
      uri = URI.parse(payload.fetch('server'))
      ticket = URI.decode_www_form(uri.query).to_h.fetch('janus_ticket')

      expect(payload.except('server', 'ice_servers')).to eq(offer)
      expect(uri.path).to eq('/janus-sipuni')
      expect(payload['ice_servers']).to eq([{ 'urls' => ['stun:stun.example.test:3478'] }])
      expect(Telephony::JanusWebsocketTicket.valid?(ticket: ticket, origin: 'https://app.example.test', path: '/janus-sipuni')).to be(true)
      expect(account.telephony_sip_profiles).to be_empty
    end

    it 'does not give another operator the room credentials' do
      other_user = create(:user, account: account, role: :administrator)
      expect(described_class.browser_payload(call: call, user: other_user)).to be_nil
    end

    it 'does not give unaccepted ringing calls a browser configuration' do
      call.update!(status: 'ringing', accepted_by_agent_id: nil)
      expect(described_class.browser_payload(call: call, user: user)).to be_nil
    end

    it 'allows only the owner of a prepared outgoing call to preconnect' do
      call.update!(status: 'ringing', direction: :outgoing, meta: call.meta.merge('outbound_prepare_pending' => true))
      expect(described_class.browser_payload(call: call, user: user)).to include('transport' => 'janus_audiobridge')
    end

    it 'does not expose credentials after the call ends' do
      call.update!(status: 'completed')
      expect(described_class.browser_payload(call: call, user: user)).to be_nil
    end

    it 'requires continuing conversation access' do
      call
      user.account_users.find_by!(account_id: account.id).update!(role: :agent)
      InboxMember.where(inbox_id: call.inbox_id, user_id: user.id).delete_all
      expect(described_class.browser_payload(call: call, user: user)).to be_nil
    end

    it 'fails closed when an accepted call still contains the previous SDP transport' do
      call.update!(meta: { 'agent_offer' => { 'sdp_offer' => 'v=0', 'peer_id' => 'old' } })
      expect { described_class.browser_payload(call: call, user: user) }.to raise_error(described_class::InvalidConfig)
    end
  end

  describe '.server_url!' do
    it 'uses the configured common Janus endpoint' do
      with_modified_env('TELEPHONY_JANUS_WS_URL' => 'wss://app.example.test/janus-asterisk') do
        expect(described_class.server_url!).to eq('wss://app.example.test/janus-asterisk')
      end
    end

    it 'refuses non-WebSocket URLs' do
      with_modified_env('TELEPHONY_JANUS_WS_URL' => 'https://untrusted.test') do
        expect { described_class.server_url! }.to raise_error(described_class::InvalidConfig)
      end
    end
  end
end
