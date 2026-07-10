require 'rails_helper'

RSpec.describe Telephony::JanusWebsocketTicket do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_voice, :sipuni, account: account) }
  let(:profile) do
    create(
      :telephony_sip_profile,
      account: account,
      inbox: channel.inbox,
      user: user,
      availability_mode: 'browser_webphone',
      status: 'active',
      enabled: true
    )
  end
  let(:server_url) { 'wss://app.one-link.kz/janus-sipuni' }

  describe '.url_for' do
    it 'adds a signed profile-scoped ticket without changing the endpoint' do
      url = described_class.url_for(
        server_url: server_url,
        account: account,
        user: user,
        sip_profile: profile
      )
      uri = URI.parse(url)
      ticket = URI.decode_www_form(uri.query).to_h.fetch('janus_ticket')

      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(server_url)
      expect(
        described_class.valid?(
          ticket: ticket,
          origin: 'https://app.one-link.kz',
          path: '/janus-sipuni'
        )
      ).to be(true)
    end
  end

  describe '.valid?' do
    subject(:authorized) do
      described_class.valid?(
        ticket: ticket,
        origin: origin,
        path: path
      )
    end

    let(:ticket) do
      described_class.issue(
        server_url: server_url,
        account: account,
        user: user,
        sip_profile: profile
      )
    end
    let(:origin) { 'https://app.one-link.kz' }
    let(:path) { '/janus-sipuni' }

    it 'rejects a ticket for another browser origin' do
      expect(authorized).to be(true)
      expect(described_class.valid?(ticket: ticket, origin: 'https://evil.example', path: path)).to be(false)
    end

    it 'rejects a ticket for another Janus endpoint' do
      expect(described_class.valid?(ticket: ticket, origin: origin, path: '/janus-asterisk')).to be(false)
    end

    it 'revokes existing tickets when the SIP profile is disabled' do
      expect(authorized).to be(true)

      profile.update!(enabled: false)

      expect(described_class.valid?(ticket: ticket, origin: origin, path: path)).to be(false)
    end

    it 'revokes existing tickets when account membership is removed' do
      expect(authorized).to be(true)

      AccountUser.find_by!(account_id: account.id, user_id: user.id).destroy!

      expect(described_class.valid?(ticket: ticket, origin: origin, path: path)).to be(false)
    end

    it 'rejects malformed tickets' do
      expect(described_class.valid?(ticket: 'not-signed', origin: origin, path: path)).to be(false)
    end
  end

  describe '.authorize?' do
    let(:ticket) do
      described_class.issue(
        server_url: server_url,
        account: account,
        user: user,
        sip_profile: profile
      )
    end

    it 'atomically allows only one concurrent consumption' do
      profile
      allow(described_class).to receive(:active_profile?).and_return(true)

      results = Array.new(8) do
        Thread.new do
          described_class.authorize?(
            ticket: ticket,
            origin: 'https://app.one-link.kz',
            path: '/janus-sipuni'
          )
        end
      end.map(&:value)

      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(7)
    end
  end
end
