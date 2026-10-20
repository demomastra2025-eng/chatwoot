require 'rails_helper'

RSpec.describe SuperAdmin::AppConfigAddresses do
  let(:base) { 'https://app.example.test' }

  def pairs(config)
    described_class.for(config, base).map { |address| [address.kind, address.url] }
  end

  it 'gives the return address of Google and Microsoft the way the application builds it' do
    expect(pairs('google')).to eq([[:redirect, 'https://app.example.test/google/callback']])
    expect(pairs('microsoft')).to eq([[:redirect, 'https://app.example.test/microsoft/callback']])
  end

  it 'gives the webhook of Messenger (mounted at /bot) and of WhatsApp' do
    expect(pairs('facebook')).to eq([[:webhook, 'https://app.example.test/bot']])
    expect(pairs('whatsapp_embedded')).to eq([[:webhook, 'https://app.example.test/webhooks/whatsapp']])
  end

  it 'gives Instagram and TikTok the webhook and the return address' do
    expect(pairs('instagram')).to eq([[:webhook, 'https://app.example.test/webhooks/instagram'], [:redirect, 'https://app.example.test/instagram/callback']])
    expect(pairs('tiktok')).to eq([[:webhook, 'https://app.example.test/webhooks/tiktok'], [:redirect, 'https://app.example.test/tiktok/callback']])
  end

  it 'gives nothing to a page that has no console to copy into' do
    expect(pairs('general')).to eq([])
    expect(pairs('slack')).to eq([])
  end

  it 'does not double the slash of the address of the platform' do
    expect(described_class.for('google', 'https://app.example.test/').first.url).to eq('https://app.example.test/google/callback')
  end

  it 'points at routes that exist (the webhook of Messenger is a mounted application)' do
    routes = Rails.application.routes.routes.map { |route| route.path.spec.to_s.sub('(.:format)', '') }

    described_class::PATHS.each_value do |entries|
      entries.each { |entry| expect(routes).to include(entry.last), entry.last }
    end
  end

  describe '.base_url' do
    let(:request) { instance_double(ActionDispatch::Request, base_url: 'http://other.test') }

    it 'is the address the platform builds its own return addresses from' do
      with_modified_env(FRONTEND_URL: 'https://front.example.test') do
        expect(described_class.base_url(request)).to eq('https://front.example.test')
      end
    end

    it 'is the address the page was opened on when the server has none' do
      with_modified_env(FRONTEND_URL: nil) do
        expect(described_class.base_url(request)).to eq('http://other.test')
      end
    end
  end
end
