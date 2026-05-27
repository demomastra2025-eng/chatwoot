require 'rails_helper'

RSpec.describe Api::V1::InboxesHelper, type: :helper do
  describe '#inbox_name' do
    it 'uses generated Weixin inbox name instead of requiring a top-level name' do
      channel = build(:channel_weixin, display_name: 'Main WeChat')

      expect(helper.inbox_name(channel)).to eq('Main WeChat')
    end

    it 'falls back to the default Weixin inbox name when display name is omitted' do
      channel = build(:channel_weixin, display_name: nil, provider_account_id: nil)

      expect(helper.inbox_name(channel)).to eq('Weixin Personal')
    end
  end

  describe '#validate_imap' do
    let(:channel_data) do
      ActionController::Parameters.new(
        imap_enabled: true,
        imap_address: 'imap.example.com',
        imap_port: 993,
        imap_login: 'support@example.com',
        imap_password: 'password',
        imap_enable_ssl: true,
        imap_authentication: 'login'
      ).permit!
    end

    it 'uses selected LOGIN auth when validating IMAP settings' do
      imap = instance_double(Net::IMAP, disconnected?: false)

      allow(Net::IMAP).to receive(:new)
        .with('imap.example.com', port: 993, ssl: true)
        .and_return(imap)
      allow(imap).to receive(:login).with('support@example.com', 'password')
      allow(imap).to receive(:disconnect)

      helper.send(:validate_imap, channel_data)

      expect(imap).to have_received(:login).with('support@example.com', 'password')
      expect(imap).to have_received(:disconnect)
    end

    it 'rejects unsupported IMAP auth mechanism before connecting' do
      channel_data[:imap_authentication] = 'oauthbearer'

      expect(Net::IMAP).not_to receive(:new)
      expect { helper.send(:validate_imap, channel_data) }
        .to raise_error(StandardError, /Invalid IMAP authentication mechanism/)
    end
  end
end
