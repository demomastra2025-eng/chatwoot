require 'rails_helper'

RSpec.describe SuperAdmin::InstallationConfigs do
  describe '.secret?' do
    it 'is true for the parameters the catalogue marks as secret' do
      expect(described_class.secret?('FB_APP_SECRET')).to be(true)
      expect(described_class.secret?('CAPTAIN_OPENROUTER_API_KEY')).to be(true)
      expect(described_class.secret?('FIREBASE_CREDENTIALS')).to be(true)
      expect(described_class.secret?('WHATSAPP_WEBHOOK_VERIFY_TOKEN')).to be(true)
    end

    it 'is true for a name that ends like a secret, even when the catalogue does not know it' do
      %w[SOME_SERVICE_SECRET SOME_API_KEY NEW_PASSWORD MY_PRIVATE_KEY SERVICE_TOKEN].each do |name|
        expect(described_class.secret?(name)).to be(true), name
      end
    end

    it 'is false for an ordinary parameter and for a switch that only has a secret-like name' do
      expect(described_class.secret?('FB_APP_ID')).to be(false)
      expect(described_class.secret?('ENABLE_ACCOUNT_SIGNUP')).to be(false)
      expect(described_class.secret?('WIDGET_TOKEN_EXPIRY')).to be(false)
      expect(described_class.secret?('ACCOUNT_CAPTAIN_TOKENS_LIMIT')).to be(false)
      expect(described_class.secret?('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN')).to be(false)
    end
  end

  describe '.page_for' do
    it 'names the settings page that edits the parameter' do
      expect(described_class.page_for('FB_APP_ID')).to eq('facebook')
      expect(described_class.page_for('WHATSAPP_APP_SECRET')).to eq('whatsapp_embedded')
      expect(described_class.page_for('CAPTAIN_DEFAULT_MODEL')).to eq('captain')
      expect(described_class.page_for('ENABLE_ACCOUNT_SIGNUP')).to eq('general')
      expect(described_class.page_for('BRAND_NAME')).to eq('custom_branding')
    end

    it 'is nil for a parameter no page edits' do
      expect(described_class.page_for('SOMETHING_ELSE')).to be_nil
    end

    it 'only names pages that exist' do
      pages = SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.keys + %w[general custom_branding]

      expect(described_class.page_map.values.uniq - pages).to be_empty
    end
  end

  describe '.display' do
    def config(name, value) = InstallationConfig.new(name: name).tap { |row| row.value = value }

    it 'says only whether a secret is set' do
      expect(described_class.display(config('FB_APP_SECRET', 'abc123')).to_h).to eq(kind: :secret_set, text: nil)
      expect(described_class.display(config('FB_APP_SECRET', '')).to_h).to eq(kind: :secret_unset, text: nil)
      expect(described_class.display(config('FB_APP_SECRET', nil)).to_h).to eq(kind: :secret_unset, text: nil)
    end

    it 'hides the value of a row the catalogue does not know' do
      expect(described_class.display(config('SOMETHING_ELSE', 'anything')).to_h).to eq(kind: :hidden, text: nil)
      expect(described_class.display(config('SOMETHING_ELSE', nil)).to_h).to eq(kind: :empty, text: nil)
    end

    it 'shows the text of an ordinary parameter, a list or a map as JSON, and cuts a long one' do
      expect(described_class.display(config('FB_APP_ID', '12345')).to_h).to eq(kind: :value, text: '12345')
      expect(described_class.display(config('ENABLE_ACCOUNT_SIGNUP', false)).text).to eq('false')
      expect(described_class.display(config('ACCOUNT_EMAILS_PLAN_LIMITS', { 'a' => 1 })).text).to eq('{"a":1}')
      expect(described_class.display(config('FB_APP_ID', 'x' * 500)).text.length).to eq(described_class::VALUE_LIMIT)
    end

    it 'shows an empty value as nothing' do
      expect(described_class.display(config('FB_APP_ID', '')).kind).to eq(:empty)
      expect(described_class.display(nil).kind).to eq(:empty)
    end
  end
end
