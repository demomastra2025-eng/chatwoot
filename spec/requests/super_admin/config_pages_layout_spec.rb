require 'rails_helper'

# The config pages as the owner sees them: only what he really sets in view, the technical settings folded under
# «Для разработчика», what does nothing not drawn at all, and a switch that changes the platform for every account says what
# it does and asks first. Saving a page never touches a setting it does not draw.
RSpec.describe 'Super admin config pages for the owner', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:allowed) do
    SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.except('captain').merge(
      'general' => SuperAdmin::AppConfigsController::DEFAULT_ALLOWED_CONFIGS,
      'custom_branding' => Enterprise::SuperAdmin::AppConfigsController::CUSTOM_BRANDING_CONFIG_KEYS
    )
  end

  before do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
    sign_in(super_admin, scope: :super_admin)
  end

  # The page of the last response (read again after every request of the example)
  def page = Nokogiri::HTML(response.body)

  def text(node)
    node.text.squish
  end

  def open_page(config)
    get '/super_admin/app_config', params: { config: config }
    expect(response).to have_http_status(:ok), "#{config}: #{response.status}"
  end

  def field(key)
    page.at_css(%([data-testid="config-fields"] [data-config="#{key}"]))
  end

  def developer
    page.at_css('[data-testid="developer-block"]')
  end

  def in_view?(key)
    node = field(key)
    node.present? && developer&.at_css(%([data-config="#{key}"])).nil?
  end

  def in_view_keys
    page.css('section[data-section] [data-config]').pluck('data-config')
  end

  def in_developer_block?(key)
    developer&.at_css(%([data-config="#{key}"])).present?
  end

  # What a browser sends when the form is submitted untouched: every control that has a name, a checkbox only when it is checked
  # (the hidden «false» before it is sent too), a disabled control never.
  def browser_params(form)
    form.css('input, select, textarea').each_with_object({}) do |node, params|
      name = node['name']
      next if name.blank? || node['disabled']

      params[name] = browser_value(node)
    end.compact
  end

  def browser_value(node)
    case node.name
    when 'textarea' then node.text.delete_prefix("\n")
    when 'select' then (node.at_css('option[selected]') || node.at_css('option'))&.[]('value')
    else input_value(node)
    end
  end

  def input_value(node)
    case node['type']
    when 'submit', 'button' then nil
    when 'checkbox', 'radio' then node['checked'] ? node['value'] : nil
    else node['value'].to_s
    end
  end

  def submit_untouched(config)
    open_page(config)
    post "/super_admin/app_config?config=#{config}", params: browser_params(page.at_css('form[data-config-form]'))
  end

  def stored(name)
    InstallationConfig.find_by(name: name)&.value
  end

  describe 'the general parameters' do
    before { open_page('general') }

    it 'groups the signup and the limits, with a heading and a hint each' do
      headings = page.css('[data-testid="config-fields"] > section h2').map { |heading| text(heading) }

      expect(headings).to eq(['Регистрация новых аккаунтов', 'Лимиты по умолчанию и файлы'])
      expect(text(page.at_css('section[data-section="signup"] .admin-block__hint'))).to include('Решите, могут ли новые люди')
    end

    it 'keeps in view the signup, the limits for accounts and the size of files' do
      %w[ENABLE_ACCOUNT_SIGNUP HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY ACCOUNT_CONVERSATIONS_LIMIT ACCOUNT_NON_WEB_INBOXES_LIMIT
         ACCOUNT_STORAGE_BYTES_LIMIT MAXIMUM_FILE_UPLOAD_SIZE].each do |key|
        expect(in_view?(key)).to be(true), key
      end
    end

    it 'folds Firebase, the timeouts and Grafana under «Для разработчика», collapsed, with a warning and the technical names' do
      expect(developer.name).to eq('details')
      expect(developer['open']).to be_nil
      expect(text(developer.at_css('summary'))).to include('Для разработчика')
      expect(text(developer.at_css('.admin-notice--amber'))).to include('Ошибка в этих настройках может остановить')
      %w[WEBHOOK_TIMEOUT WIDGET_TOKEN_EXPIRY FIREBASE_PROJECT_ID FIREBASE_CREDENTIALS GRAFANA_OVERVIEW_DASHBOARD GRAFANA_LOGS_DASHBOARD].each do |key|
        expect(in_developer_block?(key)).to be(true), key
        expect(text(field(key).at_css('.admin-field__key'))).to eq(key)
      end
    end

    it 'does not print the technical name of a setting that is in view' do
      expect(field('ACCOUNT_CONVERSATIONS_LIMIT').at_css('.admin-field__key')).to be_nil
      expect(page.css('section[data-section] .admin-field__key')).to be_empty
    end

    it 'shows the switch of the signup as a switch, with the word of its state, and not as a list of «Да» / «Нет»' do
      row = field('ENABLE_ACCOUNT_SIGNUP')

      expect(row.at_css('select')).to be_nil
      expect(row.at_css('input.admin-switch__input[type="checkbox"][name="app_config[ENABLE_ACCOUNT_SIGNUP]"]')).to be_present
      expect(row.at_css('input[type="hidden"][name="app_config[ENABLE_ACCOUNT_SIGNUP]"][value="false"]')).to be_present
      expect(text(row.at_css('.admin-switch-line'))).to eq('Включено Выключено')
    end
  end

  describe 'the signup switch' do
    before { InstallationConfig.where(name: %w[HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY]).delete_all }

    def box
      field('ENABLE_ACCOUNT_SIGNUP').at_css('input.admin-switch__input')
    end

    it 'says in one line what it does, and asks before it is switched on or off' do
      open_page('general')

      expect(text(field('ENABLE_ACCOUNT_SIGNUP').at_css('[data-testid="switch-effect"]'))).to eq(
        'Включено — любой человек может сам создать аккаунт на странице входа. Выключено — аккаунты создаёте только вы.'
      )
      expect(box['data-confirm-on']).to include("пробный период на #{Accounts::Plans.trial_days} дн. с ИИ-агентами", 'операторы и каналы — 0',
                                                'Защита от ботов: не настроена, боты смогут создавать аккаунты')
      expect(box['data-confirm-off']).to include('Уже созданные аккаунты продолжат работать.')
    end

    it 'says that the bot protection is not set, and that only one key does not work' do
      open_page('general')
      protection = field('ENABLE_ACCOUNT_SIGNUP').at_css('[data-testid="signup-protection"]')
      expect(protection['data-state']).to eq('off')
      expect(text(protection)).to include('Не настроена: боты смогут создавать аккаунты')

      upsert_installation_config('HCAPTCHA_SITE_KEY', 'site')
      open_page('general')
      expect(field('ENABLE_ACCOUNT_SIGNUP').at_css('[data-testid="signup-protection"]')['data-state']).to eq('half')
      expect(text(field('ENABLE_ACCOUNT_SIGNUP').at_css('[data-testid="signup-protection"]'))).to include('Заполнен только один ключ')

      upsert_installation_config('HCAPTCHA_SERVER_KEY', 'server')
      open_page('general')
      expect(field('ENABLE_ACCOUNT_SIGNUP').at_css('[data-testid="signup-protection"]')['data-state']).to eq('on')
      expect(box['data-confirm-on']).to include('Защита от ботов: настроена.')
    end

    it 'has the keys of the protection next to the switch, and never prints the secret one' do
      upsert_installation_config('HCAPTCHA_SERVER_KEY', 'hcaptcha-secret-value')
      open_page('general')

      expect(field('HCAPTCHA_SITE_KEY').at_css('input[type="text"]')).to be_present
      expect(field('HCAPTCHA_SERVER_KEY').at_css('input[type="password"]')['value']).to be_nil
      expect(response.body).not_to include('hcaptcha-secret-value')
    end

    it 'saves the switch as a real true / false and writes the change to the audit log' do
      upsert_installation_config('ENABLE_ACCOUNT_SIGNUP', false)

      post '/super_admin/app_config?config=general', params: { app_config: { ENABLE_ACCOUNT_SIGNUP: 'true' } }

      expect(stored('ENABLE_ACCOUNT_SIGNUP')).to be(true)
      audit = Audited::Audit.where(auditable_type: 'InstallationConfig', action: 'update_setting').last
      expect(audit.audited_changes).to eq('name' => 'ENABLE_ACCOUNT_SIGNUP', 'value' => %w[false true])
    end

    it 'does not write a switch that says what is stored already, whatever its spelling: «false» for false, «true» for «api_only»' do
      upsert_installation_config('ENABLE_ACCOUNT_SIGNUP', 'api_only')

      post '/super_admin/app_config?config=general', params: { app_config: { ENABLE_ACCOUNT_SIGNUP: 'true' } }
      expect(stored('ENABLE_ACCOUNT_SIGNUP')).to eq('api_only')

      upsert_installation_config('ENABLE_ACCOUNT_SIGNUP', 'false')
      expect { post '/super_admin/app_config?config=general', params: { app_config: { ENABLE_ACCOUNT_SIGNUP: 'false' } } }
        .not_to(change { Audited::Audit.where(action: 'update_setting').count })
      expect(stored('ENABLE_ACCOUNT_SIGNUP')).to eq('false')
    end
  end

  describe 'the switches of Meta and WhatsApp that change the work of every channel' do
    before { allow(Channel::FacebookPage).to receive(:count).and_return(3) }

    it 'sit under «Для разработчика» with one line of effect and a question that names the channels it reaches' do
      open_page('facebook')

      expect(in_developer_block?('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')).to be(true)
      row = field('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')
      expect(text(row.at_css('[data-testid="switch-effect"]'))).to include('7 дней вместо 24 часов', 'Подключено страниц: 3')
      box = row.at_css('input.admin-switch__input')
      expect(box['data-confirm-on']).to include('Включить тег «человек-оператор»', '(подключено: 3)')
      expect(box['data-confirm-off']).to include('в течение 24 часов', '(подключено страниц: 3)')
    end

    it 'do the same on the page of WhatsApp' do
      open_page('whatsapp_embedded')

      %w[WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN].each do |key|
        expect(in_developer_block?(key)).to be(true), key
        row = field(key)
        expect(row.at_css('select')).to be_nil
        expect(row.at_css('[data-testid="switch-effect"]')).to be_present
        expect(row.at_css('input.admin-switch__input')['data-confirm-on']).to be_present
        expect(row.at_css('input.admin-switch__input')['data-confirm-off']).to be_present
      end
    end

    it 'are not asked about when they stay as they are, and the browser sends them unchanged' do
      upsert_installation_config('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', true)
      open_page('facebook')

      expect(field('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT').at_css('input.admin-switch__input')['checked']).to be_present
    end
  end

  describe 'the page of Facebook, Instagram and TikTok' do
    it 'keeps in view the id and the secret of the app, with their titles, and the tokens and the version under the developer block' do
      open_page('facebook')

      expect(in_view?('FB_APP_ID')).to be(true)
      expect(in_view?('FB_APP_SECRET')).to be(true)
      %w[FB_VERIFY_TOKEN IG_VERIFY_TOKEN FACEBOOK_API_VERSION].each { |key| expect(in_developer_block?(key)).to be(true), key }
      expect(text(field('FB_VERIFY_TOKEN').at_css('.admin-field__title'))).to eq('Facebook: токен проверки вебхука')

      open_page('instagram')
      expect(in_view_keys).to eq(%w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET])
      open_page('tiktok')
      expect(in_view_keys).to eq(%w[TIKTOK_APP_ID TIKTOK_APP_SECRET])
      expect(in_developer_block?('TIKTOK_API_VERSION')).to be(true)
    end

    it 'gives the addresses to copy into the console of Meta, as text with a copy button, and not as a field' do
      with_modified_env(FRONTEND_URL: 'https://app.example.test') { open_page('instagram') }

      block = page.at_css('[data-testid="addresses-block"]')
      expect(text(block.at_css('h2'))).to eq('Что указать в кабинете Meta')
      expect(block.css('[data-testid="address-url"]').map { |node| text(node) })
        .to eq(%w[https://app.example.test/webhooks/instagram https://app.example.test/instagram/callback])
      expect(block.css('button[data-copy]').pluck('data-copy')).to eq(%w[https://app.example.test/webhooks/instagram https://app.example.test/instagram/callback])
      expect(text(block.at_css('button[data-copy]'))).to eq('Скопировать')
      expect(block.at_css('input')).to be_nil
    end

    it 'gives the webhook of Messenger and none to Slack' do
      with_modified_env(FRONTEND_URL: 'https://app.example.test') { open_page('facebook') }
      expect(page.css('[data-testid="address-url"]').map { |node| text(node) }).to eq(%w[https://app.example.test/bot])

      open_page('slack')
      expect(page.at_css('[data-testid="addresses-block"]')).to be_nil
    end

    it 'shows the built-in version of an API in the empty field, and says so' do
      open_page('whatsapp_embedded')

      row = field('WHATSAPP_API_VERSION')
      expect(row.at_css('input')['placeholder']).to eq('v25.0')
      expect(text(row)).to include('По умолчанию: v25.0')
    end
  end

  describe 'the page of WhatsApp' do
    before do
      upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_TARGETS', '{"dev":"https://dev.one-link.kz/webhooks/whatsapp","widget":"https://medelement.one-link.kz/webhooks/meta/whatsapp"}')
      upsert_installation_config('WHATSAPP_WEBHOOK_ROUTING_RULES', '{"123456":["dev"]}')
      open_page('whatsapp_embedded')
    end

    it 'keeps in view the id of the app, its secret and the id of the configuration, and nothing else' do
      expect(in_view_keys).to eq(%w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID])
    end

    it 'shows the forward targets as text: no control, no name in the form' do
      row = field('WHATSAPP_WEBHOOK_FORWARD_TARGETS')

      expect(in_developer_block?('WHATSAPP_WEBHOOK_FORWARD_TARGETS')).to be(true)
      expect(row['data-readonly']).to eq('true')
      expect(row.css('input, textarea, select')).to be_empty
      expect(text(row.at_css('[data-testid="forward-targets"]'))).to eq(
        'DEV https://dev.one-link.kz/webhooks/whatsapp МедЭлемент https://medelement.one-link.kz/webhooks/meta/whatsapp'
      )
      expect(text(row)).to include('Только для просмотра')
      expect(page.css('[name]').pluck('name')).not_to include('app_config[WHATSAPP_WEBHOOK_FORWARD_TARGETS]')
    end

    it 'keeps the routing rules editable, under «Для разработчика»' do
      row = field('WHATSAPP_WEBHOOK_ROUTING_RULES')

      expect(in_developer_block?('WHATSAPP_WEBHOOK_ROUTING_RULES')).to be(true)
      expect(row.at_css('input[name="app_config[WHATSAPP_WEBHOOK_ROUTING_RULES]"]')['value']).to eq('{"123456":["dev"]}')
    end

    it 'says that the name of the environment stays empty on the working server' do
      expect(text(field('WHATSAPP_WEBHOOK_RECEIVER_DESTINATION'))).to include('На рабочем сервере оставьте пустым.')
    end

    it 'says «Не задано» when the targets are not set or cannot be read' do
      upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_TARGETS', 'not json')
      open_page('whatsapp_embedded')

      expect(text(field('WHATSAPP_WEBHOOK_FORWARD_TARGETS').at_css('[data-testid="forward-targets"]'))).to eq('Не задано')
    end
  end

  describe 'the page of Google' do
    it 'does not offer the return address as a field: it gives the address to copy into Google Cloud Console' do
      with_modified_env(FRONTEND_URL: 'https://app.example.test') { open_page('google') }

      expect(field('GOOGLE_OAUTH_REDIRECT_URI')).to be_nil
      expect(page.css('[name]').pluck('name')).not_to include('app_config[GOOGLE_OAUTH_REDIRECT_URI]')
      block = page.at_css('[data-testid="addresses-block"]')
      expect(text(block.at_css('h2'))).to eq('Что указать в Google Cloud Console')
      expect(text(block.at_css('[data-testid="address-url"]'))).to eq('https://app.example.test/google/callback')
    end

    it 'has the switch of the login through Google inactive, saying the server needs a setup, while the server is not set up' do
      with_modified_env(GOOGLE_OAUTH_CLIENT_ID: nil, GOOGLE_OAUTH_CALLBACK_URL: nil) { open_page('google') }

      row = field('ENABLE_GOOGLE_OAUTH_LOGIN')
      expect(row.at_css('input.admin-switch__input')['disabled']).to be_present
      expect(row.at_css('input[type="hidden"]')).to be_nil
      expect(text(row.at_css('[data-testid="google-login-note"]'))).to include('Нужна настройка сервера')
    end

    it 'has the switch working, and asking first, once the server is set up' do
      with_modified_env(GOOGLE_OAUTH_CLIENT_ID: 'client', GOOGLE_OAUTH_CALLBACK_URL: 'https://app.example.test/omniauth/google_oauth2/callback') do
        open_page('google')
      end

      row = field('ENABLE_GOOGLE_OAUTH_LOGIN')
      expect(row.at_css('input.admin-switch__input')['disabled']).to be_nil
      expect(row.at_css('[data-testid="google-login-note"]')).to be_nil
      expect(row.at_css('input.admin-switch__input')['data-confirm-on']).to eq('Показать вход через Google на странице входа всех операторов?')
    end

    it 'keeps the stored switch when the server is not set up: the inactive switch is not sent' do
      upsert_installation_config('ENABLE_GOOGLE_OAUTH_LOGIN', true)
      upsert_installation_config('GOOGLE_OAUTH_REDIRECT_URI', 'https://old.example.test/cb')
      with_modified_env(GOOGLE_OAUTH_CLIENT_ID: nil, GOOGLE_OAUTH_CALLBACK_URL: nil) do
        open_page('google')
        params = browser_params(page.at_css('form[data-config-form]'))
        expect(params.keys).not_to include('app_config[ENABLE_GOOGLE_OAUTH_LOGIN]')
        post '/super_admin/app_config?config=google', params: params
      end

      expect(stored('ENABLE_GOOGLE_OAUTH_LOGIN')).to be(true)
      expect(stored('GOOGLE_OAUTH_REDIRECT_URI')).to eq('https://old.example.test/cb')
    end
  end

  describe 'the page of the letters' do
    it 'keeps in view the limit of letters per day, and puts the domain of the incoming mail under the developer block' do
      open_page('email')

      expect(in_view?('ACCOUNT_EMAILS_LIMIT')).to be(true)
      expect(in_developer_block?('MAILER_INBOUND_EMAIL_DOMAIN')).to be(true)
    end

    it 'does not draw the limits of letters by tariff, which the system never applies' do
      upsert_installation_config('ACCOUNT_EMAILS_PLAN_LIMITS', { 'startups' => 10 })
      open_page('email')

      expect(field('ACCOUNT_EMAILS_PLAN_LIMITS')).to be_nil
      expect(response.body).not_to include('ACCOUNT_EMAILS_PLAN_LIMITS')
    end
  end

  describe 'the page of the brand' do
    it 'has its own settings: the names and logos in view, the links and the manifest under the developer block' do
      open_page('custom_branding')

      expect(text(page.at_css('h1'))).to eq('Брендирование')
      expect(in_view_keys).to eq(%w[BRAND_NAME INSTALLATION_NAME LOGO LOGO_DARK LOGO_THUMBNAIL TERMS_URL PRIVACY_URL])
      %w[BRAND_URL WIDGET_BRAND_URL DISPLAY_MANIFEST].each { |key| expect(in_developer_block?(key)).to be(true), key }
      expect(field('DISPLAY_MANIFEST').at_css('input.admin-switch__input')['data-confirm-on']).to be_nil
    end

    it 'never shows the general parameters under its name: where the function is not available the address is not found' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/app_config?config=custom_branding'

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('app_config[ENABLE_ACCOUNT_SIGNUP]')
    end
  end

  describe 'every page' do
    it 'draws without a missing translation, every control of its layout is on the page, and what is not shown is not' do
      SuperAdmin::AppConfigLayout.configs.each do |config|
        open_page(config)
        layout = SuperAdmin::AppConfigLayout.page(config, allowed.fetch(config))

        expect(response.body).not_to include('translation missing'), config
        (layout.editable_keys + layout.read_only).each { |key| expect(field(key)).to be_present, "#{config}: #{key}" }
        layout.hidden.each { |key| expect(field(key)).to be_nil, "#{config}: #{key} is drawn" }
      end
    end

    it 'has no block «Для разработчика» on a page that has nothing technical' do
      open_page('slack')

      expect(developer).to be_nil
    end
  end

  describe 'saving a page that has fields it does not draw' do
    it 'keeps the stored value of every setting that is not drawn, and of the text it only shows' do
      upsert_installation_config('ACCOUNT_EMAILS_PLAN_LIMITS', { 'startups' => 10 })
      upsert_installation_config('GOOGLE_OAUTH_REDIRECT_URI', 'https://old.example.test/cb')
      upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_TARGETS', '{"dev":"https://dev.one-link.kz/webhooks/whatsapp","widget":"https://medelement.one-link.kz/webhooks/meta/whatsapp"}')
      upsert_installation_config('ACCOUNT_EMAILS_LIMIT', '100')

      submit_untouched('email')
      submit_untouched('google')
      submit_untouched('whatsapp_embedded')

      expect(stored('ACCOUNT_EMAILS_PLAN_LIMITS')).to eq('startups' => 10)
      expect(stored('GOOGLE_OAUTH_REDIRECT_URI')).to eq('https://old.example.test/cb')
      expect(stored('WHATSAPP_WEBHOOK_FORWARD_TARGETS')).to eq('{"dev":"https://dev.one-link.kz/webhooks/whatsapp","widget":"https://medelement.one-link.kz/webhooks/meta/whatsapp"}')
      expect(stored('ACCOUNT_EMAILS_LIMIT')).to eq('100')
    end

    it 'keeps the settings under «Для разработчика» when the page is saved untouched, and writes nothing to the audit log for them' do
      upsert_installation_config('FACEBOOK_API_VERSION', 'v19.0')
      upsert_installation_config('FB_VERIFY_TOKEN', 'verify-token')
      upsert_installation_config('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', true)
      upsert_installation_config('FB_APP_ID', '123')
      Audited::Audit.where(action: 'update_setting').delete_all

      submit_untouched('facebook')

      expect(response).to redirect_to(super_admin_app_config_path(config: 'facebook'))
      expect(stored('FACEBOOK_API_VERSION')).to eq('v19.0')
      expect(stored('FB_VERIFY_TOKEN')).to eq('verify-token')
      expect(stored('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')).to be(true)
      logged = Audited::Audit.where(action: 'update_setting').map { |audit| audit.audited_changes['name'] }
      expect(logged).not_to include('FACEBOOK_API_VERSION', 'ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')
    end

    it 'keeps the secrets that are set, when the page is saved untouched' do
      upsert_installation_config('FB_APP_SECRET', 'stored-secret')
      upsert_installation_config('WHATSAPP_APP_SECRET', 'whatsapp-secret')
      upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_SECRET', 'forward-secret')

      submit_untouched('facebook')
      submit_untouched('whatsapp_embedded')

      expect(stored('FB_APP_SECRET')).to eq('stored-secret')
      expect(stored('WHATSAPP_APP_SECRET')).to eq('whatsapp-secret')
      expect(stored('WHATSAPP_WEBHOOK_FORWARD_SECRET')).to eq('forward-secret')
    end

    it 'writes nothing for an empty field of a setting that has no value (an empty row would stop the fall back to the server)' do
      InstallationConfig.where(name: %w[HCAPTCHA_SITE_KEY FIREBASE_PROJECT_ID ENABLE_ACCOUNT_SIGNUP]).delete_all
      Audited::Audit.where(action: 'update_setting').delete_all

      submit_untouched('general')

      expect(InstallationConfig.where(name: %w[HCAPTCHA_SITE_KEY FIREBASE_PROJECT_ID])).to be_empty
      expect(Audited::Audit.where(action: 'update_setting')).to be_empty
    end

    it 'still clears a field the owner emptied: an empty value over a stored one is a change' do
      upsert_installation_config('HCAPTCHA_SITE_KEY', 'old-site-key')

      post '/super_admin/app_config?config=general', params: { app_config: { HCAPTCHA_SITE_KEY: '' } }

      expect(stored('HCAPTCHA_SITE_KEY')).to eq('')
    end

    it 'still saves what was changed on the page, in view or under «Для разработчика»' do
      upsert_installation_config('FB_APP_ID', 'old')
      upsert_installation_config('FACEBOOK_API_VERSION', 'v18.0')

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'new', FACEBOOK_API_VERSION: 'v20.0' } }

      expect(stored('FB_APP_ID')).to eq('new')
      expect(stored('FACEBOOK_API_VERSION')).to eq('v20.0')
    end
  end

  describe 'the version of an API' do
    before { upsert_installation_config('WHATSAPP_API_VERSION', 'v25.0') }

    it 'must look like «v25.0»: a text that does not is refused in Russian and the stored version stays' do
      post '/super_admin/app_config?config=whatsapp_embedded', params: { app_config: { WHATSAPP_API_VERSION: '25' } }

      expect(flash[:alert]).to eq('WhatsApp: версия API: версия должна выглядеть как v25.0 (буква v, число, точка и число).')
      expect(stored('WHATSAPP_API_VERSION')).to eq('v25.0')
    end

    it 'accepts «v22.0» and «v1.3», and a version without a point' do
      %w[v22.0 v1.3 v21].each do |version|
        post '/super_admin/app_config?config=whatsapp_embedded', params: { app_config: { WHATSAPP_API_VERSION: version } }

        expect(stored('WHATSAPP_API_VERSION')).to eq(version)
      end
    end

    it 'never saves an empty version over the stored one' do
      post '/super_admin/app_config?config=whatsapp_embedded', params: { app_config: { WHATSAPP_API_VERSION: '  ' } }

      expect(stored('WHATSAPP_API_VERSION')).to eq('v25.0')
      expect(flash[:alert]).to be_blank
    end

    it 'refuses every API version of the other pages the same way' do
      { 'facebook' => 'FACEBOOK_API_VERSION', 'instagram' => 'INSTAGRAM_API_VERSION', 'tiktok' => 'TIKTOK_API_VERSION' }.each do |config, key|
        upsert_installation_config(key, 'v1.0')

        post "/super_admin/app_config?config=#{config}", params: { app_config: { key => 'latest' } }

        expect(stored(key)).to eq('v1.0'), key
      end
    end
  end
end
