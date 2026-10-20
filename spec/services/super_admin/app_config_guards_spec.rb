require 'rails_helper'

RSpec.describe SuperAdmin::AppConfigGuards do
  def stub_channel_counts(facebook: 0, instagram: 0, whatsapp: 0)
    allow(Channel::FacebookPage).to receive(:count).and_return(facebook)
    allow(Channel::Instagram).to receive(:count).and_return(instagram)
    allow(Channel::Whatsapp).to receive(:where).with(provider: 'whatsapp_cloud').and_return(instance_double(ActiveRecord::Relation, count: whatsapp))
  end

  it 'knows the switches that change the platform for every account, and no other' do
    expect(described_class::KEYS).to match_array(
      %w[ENABLE_ACCOUNT_SIGNUP ENABLE_GOOGLE_OAUTH_LOGIN ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT
         WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN]
    )
    expect(described_class.for('DISPLAY_MANIFEST')).to be_nil
    expect(described_class.guarded?('FB_APP_ID')).to be(false)
  end

  it 'says in Russian, for every switch, what it does and what both changes mean' do
    stub_channel_counts(facebook: 2, instagram: 1, whatsapp: 4)

    described_class::KEYS.each do |key|
      guard = described_class.for(key)

      [guard.effect, guard.confirm_on, guard.confirm_off].each do |text|
        expect(text).to match(/\p{Cyrillic}/), key
        expect(text).not_to include('translation missing', '%{'), key
      end
    end
  end

  it 'names how many connected channels of the kind a change reaches' do
    stub_channel_counts(facebook: 3, instagram: 5, whatsapp: 7)

    expect(described_class.for('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT').confirm_on).to include('подключено: 3')
    expect(described_class.for('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT').confirm_off).to include('подключено каналов: 5')
    expect(described_class.for('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN').effect).to include('Подключено каналов: 7')
    expect(described_class.for('WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED').confirm_on).to include('подключено каналов: 7')
  end

  it 'counts the real channels: a page of Messenger, an Instagram channel, and only the WhatsApp Cloud ones' do
    create(:channel_instagram_fb_page)
    create(:channel_instagram)
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    create(:channel_whatsapp, sync_templates: false, validate_provider_config: false)

    expect(described_class.for('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT').effect).to include('Подключено страниц: 1')
    expect(described_class.for('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT').effect).to include('Подключено каналов: 1')
    expect(described_class.for('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN').effect).to include('Подключено каналов: 1')
  end

  describe 'the question before the signup of accounts is switched on' do
    before { InstallationConfig.where(name: %w[HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY]).delete_all }

    it 'says what every new account gets and that the bot protection is not set' do
      question = described_class.for('ENABLE_ACCOUNT_SIGNUP').confirm_on

      expect(question).to include("пробный период на #{Accounts::Plans.trial_days} дн.", 'ИИ-агентами', 'операторы и каналы — 0',
                                  'Защита от ботов: не настроена, боты смогут создавать аккаунты')
    end

    it 'says the protection is set when both keys of hCaptcha are stored' do
      upsert_installation_config('HCAPTCHA_SITE_KEY', 'site-key')
      upsert_installation_config('HCAPTCHA_SERVER_KEY', 'server-key')

      expect(described_class.for('ENABLE_ACCOUNT_SIGNUP').confirm_on).to include('Защита от ботов: настроена.')
    end

    it 'does not call the protection set while one of the two keys is missing' do
      upsert_installation_config('HCAPTCHA_SERVER_KEY', 'server-key')

      expect(described_class.protection_configured?).to be(false)
    end
  end
end
