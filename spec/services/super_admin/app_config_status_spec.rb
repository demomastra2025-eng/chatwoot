require 'rails_helper'

RSpec.describe SuperAdmin::AppConfigStatus do
  let(:pages) { %w[general custom_branding email facebook instagram tiktok whatsapp_embedded google microsoft slack] }

  def status(config)
    described_class.new(pages: pages).entries.find { |entry| entry.config == config }&.configured
  end

  before { InstallationConfig.where(name: described_class::REQUIRED.values.flatten).delete_all }

  it 'lists the pages of the platform first and the connections after, in the order of the sidebar, with the AI models page' do
    entries = described_class.new(pages: pages).entries

    expect(entries.map(&:config)).to eq(%w[general captain custom_branding email facebook instagram tiktok whatsapp_embedded google microsoft slack])
    expect(entries.map(&:group).uniq).to eq(%i[platform connections])
  end

  it 'leaves out a page the installation does not offer' do
    entries = described_class.new(pages: %w[general facebook]).entries

    expect(entries.map(&:config)).to eq(%w[general captain facebook])
  end

  it 'has no status for the pages with nothing to connect' do
    expect(status('general')).to be_nil
    expect(status('custom_branding')).to be_nil
  end

  it 'counts a page as set up only when everything the connection cannot work without is stored' do
    expect(status('facebook')).to be(false)

    upsert_installation_config('FB_APP_ID', '123')
    expect(status('facebook')).to be(false)

    upsert_installation_config('FB_APP_SECRET', 'secret')
    expect(status('facebook')).to be(true)
  end

  it 'needs the configuration id of WhatsApp together with the application' do
    upsert_installation_config('WHATSAPP_APP_ID', '1')
    upsert_installation_config('WHATSAPP_APP_SECRET', 's')

    expect(status('whatsapp_embedded')).to be(false)

    upsert_installation_config('WHATSAPP_CONFIGURATION_ID', 'c')
    expect(status('whatsapp_embedded')).to be(true)
  end

  it 'does not count an empty value' do
    upsert_installation_config('MAILER_INBOUND_EMAIL_DOMAIN', '')

    expect(status('email')).to be(false)
  end

  describe 'the AI models page' do
    it 'is set up when the key of OpenRouter is available' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)

      expect(described_class.new.configured?('captain')).to be(true)
    end

    it 'is not set up without it, and has no status when that cannot be read' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(false)
      expect(described_class.new.configured?('captain')).to be(false)

      allow(Llm::Config).to receive(:installation_provider_available?).and_raise(StandardError)
      expect(described_class.new.configured?('captain')).to be_nil
    end
  end
end
