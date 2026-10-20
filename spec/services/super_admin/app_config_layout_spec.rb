require 'rails_helper'

RSpec.describe SuperAdmin::AppConfigLayout do
  let(:mapping) do
    SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.except('captain').merge(
      'general' => SuperAdmin::AppConfigsController::DEFAULT_ALLOWED_CONFIGS,
      'custom_branding' => Enterprise::SuperAdmin::AppConfigsController::CUSTOM_BRANDING_CONFIG_KEYS
    )
  end

  def layout(config)
    described_class.page(config, mapping.fetch(config))
  end

  it 'has a layout for every page of the settings that draws a list of fields' do
    expect(described_class.configs).to match_array(mapping.keys)
  end

  it 'places every setting of every page exactly once: in view, under «Для разработчика», as text or not shown' do
    mapping.each do |config, keys|
      page = layout(config)

      expect(page.all_keys).to match_array(keys), config
      expect(page.all_keys.size).to eq(page.all_keys.uniq.size), "#{config} places a setting twice"
    end
  end

  it 'draws as controls only what the page can save' do
    mapping.each do |config, keys|
      expect(keys).to include(*layout(config).editable_keys), config
    end
  end

  describe 'what the owner sets' do
    it 'keeps the keys of the apps in view and the technical settings of Meta under the developer block' do
      expect(layout('facebook').shown_keys).to eq(%w[FB_APP_ID FB_APP_SECRET])
      expect(layout('facebook').developer).to eq(%w[FB_VERIFY_TOKEN IG_VERIFY_TOKEN FACEBOOK_API_VERSION ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT])
      expect(layout('instagram').shown_keys).to eq(%w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET])
      expect(layout('tiktok').developer).to eq(%w[TIKTOK_API_VERSION])
      expect(layout('whatsapp_embedded').shown_keys).to eq(%w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID])
    end

    it 'keeps the limits and the signup of the platform in view, and the timeouts, Firebase and Grafana under the developer block' do
      page = layout('general')

      expect(page.sections.map(&:id)).to eq(%w[signup limits])
      expect(page.shown_keys).to include('ENABLE_ACCOUNT_SIGNUP', 'ACCOUNT_CONVERSATIONS_LIMIT', 'ACCOUNT_STORAGE_BYTES_LIMIT',
                                         'MAXIMUM_FILE_UPLOAD_SIZE')
      expect(page.developer).to include('WEBHOOK_TIMEOUT', 'WIDGET_TOKEN_EXPIRY', 'FIREBASE_CREDENTIALS', 'GRAFANA_OVERVIEW_DASHBOARD')
    end

    it 'keeps the names and logos of the brand in view, and its links and the manifest under the developer block' do
      expect(layout('custom_branding').shown_keys).to include('BRAND_NAME', 'INSTALLATION_NAME', 'LOGO', 'LOGO_DARK', 'LOGO_THUMBNAIL')
      expect(layout('custom_branding').developer).to eq(%w[BRAND_URL WIDGET_BRAND_URL DISPLAY_MANIFEST])
    end
  end

  describe 'what does nothing, or must not be edited' do
    it 'does not show the letter limits by tariff (the system looks for a tariff name that no longer exists)' do
      expect(layout('email').hidden).to eq(%w[ACCOUNT_EMAILS_PLAN_LIMITS])
      expect(layout('email').all_keys).to include('ACCOUNT_EMAILS_LIMIT')
      expect(layout('email').editable_keys).not_to include('ACCOUNT_EMAILS_PLAN_LIMITS')
    end

    it 'does not show the return address of Google (the system never reads it)' do
      expect(layout('google').hidden).to eq(%w[GOOGLE_OAUTH_REDIRECT_URI])
      expect(layout('google').editable_keys).not_to include('GOOGLE_OAUTH_REDIRECT_URI')
    end

    it 'shows the forward targets of WhatsApp as text, under the developer block, and keeps the routing rules editable there' do
      page = layout('whatsapp_embedded')

      expect(page.read_only).to eq(%w[WHATSAPP_WEBHOOK_FORWARD_TARGETS])
      expect(page.editable_keys).not_to include('WHATSAPP_WEBHOOK_FORWARD_TARGETS')
      expect(page.developer).to include('WHATSAPP_WEBHOOK_ROUTING_RULES', 'WHATSAPP_WEBHOOK_RECEIVER_DESTINATION', 'WHATSAPP_WEBHOOK_FORWARD_SECRET')
      expect(page.shown_keys).not_to include('WHATSAPP_WEBHOOK_ROUTING_RULES')
    end
  end

  it 'puts a setting nobody has classified under the developer block (the safe place), and none of the page is lost' do
    page = described_class.page('facebook', mapping['facebook'] + %w[A_NEW_SETTING])

    expect(page.developer).to end_with('A_NEW_SETTING')
    expect(page.all_keys).to include('A_NEW_SETTING')
  end

  it 'draws a page without a layout as one list' do
    page = described_class.page('some_new_page', %w[ONE TWO])

    expect(page.sections.map(&:keys)).to eq([%w[ONE TWO]])
    expect(page.developer_block?).to be(false)
  end

  it 'asks first for every switch that changes the platform for all accounts; only the manifest of the brand is an ordinary switch' do
    definitions = ConfigLoader.new.general_configs.to_h { |config| [config['name'], config['type']] }
    switches = mapping.values.flatten.uniq.select { |key| definitions[key] == 'boolean' }

    expect(switches - SuperAdmin::AppConfigGuards::KEYS).to eq(%w[DISPLAY_MANIFEST])
  end
end
