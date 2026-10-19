# frozen_string_literal: true

require 'rails_helper'

# The settings pages of the super admin: the AI models page (cards grouped by purpose), the config pages (one list of
# fields) and the instance settings page. Everything a person reads is Russian; no secret is ever printed.
RSpec.describe 'Super admin settings pages', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }

  before do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
    sign_in(super_admin, scope: :super_admin)
  end

  def text(node)
    node.text.squish
  end

  def field(key)
    page.at_css(%([data-testid="config-fields"] [data-config="#{key}"]))
  end

  def card(key)
    page.at_css(%([data-testid="ai-models-form"] [data-config~="#{key}"]))
  end

  describe 'the AI models page' do
    let(:groups) do
      {
        'connection' => 'Подключение к OpenRouter',
        'agent' => 'Основная модель агентов',
        'safety' => 'Проверка безопасности',
        'voice' => 'Расшифровка голоса',
        'images' => 'Распознавание картинок',
        'classifiers' => 'Служебные модели: итоги диалога, язык, метки',
        'prompts' => 'Правила платформы для всех агентов'
      }
    end

    before { get '/super_admin/app_config?config=captain' }

    it 'is titled «Модели ИИ» and has no translation gaps' do
      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Модели ИИ')
      expect(response.body).not_to include('translation missing')
    end

    it 'has the tabs «Подключение», «Модели», «Промпты», and all three panels are in the one form' do
      expect(page.css('[data-testid="ai-models-form"] [data-tab-panel]').pluck('data-tab-panel')).to eq(%w[connection models prompts])
      expect(page.css('[data-tablist] [role="tab"]').map { |tab| text(tab) }).to eq(%w[Подключение Модели Промпты])
      expect(page.css('form#ai-models-form').size).to eq(1)
    end

    it 'puts the key of OpenRouter and its state first' do
      first_panel = page.at_css('[data-testid="ai-models-form"] [data-tab-panel]')

      expect(first_panel['data-tab-panel']).to eq('connection')
      expect(first_panel.at_css('[data-testid="diagnostics-key"]')).to be_present
      expect(first_panel.at_css('input#app_config_CAPTAIN_OPENROUTER_API_KEY')).to be_present
    end

    it 'groups the cards by purpose, in the order of the page' do
      headings = page.css('[data-testid="ai-models-form"] section[data-testid^="ai-group-"] h2').map { |heading| text(heading) }

      expect(headings).to eq(groups.values)
    end

    it 'puts every setting of the page in exactly one card with its own control' do
      keys = SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS

      keys.each do |key|
        expect(page.css(%([data-testid="ai-models-form"] [data-config~="#{key}"])).size).to eq(1), "card of #{key}"
      end
      (keys - %w[CAPTAIN_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST]).each do |key|
        expect(page.css(%([name="app_config[#{key}]"])).size).to eq(1), "control of #{key}"
      end
    end

    it 'gives every card a Russian title in plain words' do
      expect(text(card('CAPTAIN_MODERATION_MODEL').at_css('.admin-slot__title'))).to eq('Проверка безопасности ответов')
      expect(text(card('CAPTAIN_EMBEDDING_MODEL').at_css('.admin-slot__title'))).to eq('Поиск по базе знаний (индексация)')
      expect(text(card('CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY').at_css('.admin-slot__title'))).to eq('Ключ OpenRouter для проверки баланса (необязательно)')
      expect(text(card('CAPTAIN_FIRECRAWL_API_KEY').at_css('.admin-slot__title'))).to eq('Загрузка сайтов в базу знаний (FireCrawl, необязательно)')
      expect(text(card('CAPTAIN_OPENROUTER_API_KEY').at_css('.admin-slot__title'))).to eq('Ключ OpenRouter')
    end

    it 'keeps jargon and English display titles out of the cards' do
      titles = page.css('.admin-slot__title').map { |node| text(node) }.join(' ')

      expect(titles).not_to match(/эмбеддинг|guardrail|слот|Management|OpenRouter API Key|AI Agent Global System Prompt|AI Tokens Limit/i)
    end

    it 'shows the technical names only under the switch «Показать технические имена»' do
      toggle = page.at_css('input[data-tech-toggle]')
      names = page.css('[data-tech-name]')

      expect(toggle).to be_present
      expect(text(toggle.parent)).to eq('Показать технические имена')
      expect(names.size).to be > 10
      expect(names.map { |node| text(node) }).to include('CAPTAIN_MODERATION_MODEL', 'CAPTAIN_DEFAULT_MODEL · CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')
    end

    it 'does not offer the legacy direct-provider keys' do
      expect(response.body).not_to include('CAPTAIN_OPEN_AI_API_KEY', 'CAPTAIN_ANTHROPIC_API_KEY', 'CAPTAIN_GEMINI_API_KEY')
    end

    it 'has the entry of the scripts of the page' do
      expect(response.body).to match(%r{superadmin_ai_models})
    end
  end

  describe 'where the value of a card comes from' do
    before do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna')
      upsert_installation_config('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', '')
      upsert_installation_config('CAPTAIN_IMAGE_RECOGNITION_MODEL', '')
      upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
      get '/super_admin/app_config?config=captain'
    end

    it 'says «Вы выбрали» and offers to put the built-in model back for a setting the platform has set' do
      agents = card('CAPTAIN_DEFAULT_MODEL')

      expect(agents['data-source']).to eq('set')
      status = agents.at_css('[data-testid="slot-status"]')
      expect(text(status)).to include('Вы выбрали: GPT-5.6 Luna', 'Вернуть встроенную')
      expect(agents.at_css('input[type="radio"][value="openai/gpt-5.6-luna"]')['checked']).to be_present
    end

    it 'says «Используется встроенная» and names the built-in model for a blank slot' do
      voice = card('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')

      expect(voice['data-source']).to eq('default')
      expect(text(voice.at_css('[data-testid="slot-status"]'))).to eq('Используется встроенная: GPT-4o Mini Transcribe')
      expect(voice.at_css('select option[value=""]')['selected']).to be_present
      expect(text(voice.at_css('select option[value=""]'))).to eq('Встроенная: GPT-4o Mini Transcribe')
    end

    it 'follows the default model of the installation for a blank slot when that is its built-in value' do
      expect(text(card('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('[data-testid="slot-status"]'))).to eq('Используется встроенная: GPT-5.6 Luna')
    end

    it 'ticks the models of the short list and no others' do
      agents = card('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')
      ticked = agents.css('input[type="checkbox"][checked]').pluck('value')

      expect(ticked).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
      expect(text(agents.at_css('[data-counter]'))).to eq('2 из 12')
    end
  end

  describe 'secrets on the AI models page' do
    it 'shows only that a key is set, never the key' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-test-openrouter-secret')
      upsert_installation_config('CAPTAIN_FIRECRAWL_API_KEY', 'fc-test-firecrawl-secret')

      get '/super_admin/app_config?config=captain'

      secret_card = card('CAPTAIN_OPENROUTER_API_KEY')
      expect(text(secret_card.at_css('[data-testid="slot-source"]'))).to eq('Задан')
      input = secret_card.at_css('input[type="password"]')
      expect(input['value']).to be_nil
      expect(input['placeholder']).to eq('Задан — оставьте пустым, чтобы не менять')
      expect(response.body).not_to include('sk-test-openrouter-secret', 'fc-test-firecrawl-secret')
    end

    it 'says «Не задан» for a key that is missing' do
      InstallationConfig.where(name: 'CAPTAIN_FIRECRAWL_API_KEY').delete_all

      get '/super_admin/app_config?config=captain'

      expect(text(card('CAPTAIN_FIRECRAWL_API_KEY').at_css('[data-testid="slot-source"]'))).to eq('Не задан')
    end
  end

  describe 'OpenRouter in plain words, and the details for a developer' do
    let(:diagnostics) do
      {
        key_status: { effective_configured: true, global_configured: true, account_configured: false,
                      health: { status: 'valid', checked_at: '2026-10-15T12:05:09Z', key: { key_type: 'inference', limit: '50', limit_remaining: '12.5' },
                                credits: { status: 'available', remaining_credits: 12.5, total_credits: 100, total_usage: 87.5 } } },
        catalog: { refresh_status: 'success', source: 'openrouter_api', using_fallback: false, last_refreshed_at: '2026-10-15T12:05:09Z', total_models: 1200,
                   counts_by_type: { chat: 1000, embedding: 20 }, stale_models: 2, disabled_models: 0, last_refresh_diff: {} },
        endpoints: { refresh_status: 'running', total_endpoints: 3400, providers: %w[azure openai] },
        runtime: { total_events: 10, request_count: 8, error_count: 1, provider_failure_count: 0, estimated_cost: 0.42 },
        features: { 'assistant' => { available_model_count: 7, selected_model: 'openai/gpt-6-luna', default_model: 'openai/gpt-6-luna' } }
      }
    end

    before do
      allow(Llm::OpenRouterDiagnostics).to receive(:call).and_return(diagnostics)
      get '/super_admin/app_config?config=captain'
    end

    def block
      page.at_css('details#openrouter-diagnostics')
    end

    it 'says whether the key works, the balance, the spend and the catalog, with the currency' do
      expect(text(page.at_css('[data-testid="diagnostics-key"]'))).to include('Рабочий', 'Ключ рабочий.', 'Проверен 15.10.2026 17:05')
      expect(text(page.at_css('[data-testid="diagnostics-credits"]'))).to include('$12,50 осталось', 'Лимит ключа: $50,00, осталось $12,50')
      expect(text(page.at_css('[data-testid="diagnostics-events"]'))).to include('$0,42', '8 запросов, ошибок: 1')
      expect(text(page.at_css('[data-testid="diagnostics-catalog"]'))).to include('Загружен 15.10.2026 17:05', '1 200 моделей')
    end

    it 'keeps the two actions next to what they refresh' do
      expect(page.at_css('[data-testid="diagnostics-key"] button[form="ai-check-key-form"]')).to be_present
      expect(page.at_css('[data-testid="diagnostics-catalog"] button[form="ai-refresh-catalog-form"]')).to be_present
      expect(page.at_css('form#ai-check-key-form')['action']).to eq('/super_admin/app_config/refresh_openrouter_key_health?config=captain')
      expect(page.at_css('form#ai-refresh-catalog-form')['action']).to eq('/super_admin/app_config/refresh_openrouter_models?config=captain')
    end

    it 'puts the details under «Для разработчика», folded, with the statuses in Russian' do
      expect(page.at_css('details#ai-developer')['open']).to be_nil
      expect(page.at_css('details#ai-developer').css('details#openrouter-diagnostics')).to be_present
      expect(block['open']).to be_nil
      expect(text(block.at_css('summary'))).to include('Подробности для разработчика')
      expect(text(block.at_css('[data-testid="diagnostics-catalog-details"]'))).to include('обновлён', 'каталог OpenRouter', 'чат: 1 000')
      expect(text(block.at_css('[data-testid="diagnostics-providers"]'))).to include('обновляется', 'azure, openai')
      expect(text(block)).not_to match(/credits_exhausted|management_key_required|openrouter_api/)
    end

    it 'shows the models of a function under its Russian name' do
      feature = block.at_css('[data-feature="assistant"]')

      expect(text(feature)).to include('Основной агент', 'Доступно моделей: 7')
    end

    it 'shows moments in Astana time and numbers with a space between thousands' do
      expect(text(block)).to include('15.10.2026 17:05', '3 400')
    end

    context 'when the key is missing and the catalog was never loaded' do
      let(:diagnostics) do
        {
          key_status: { effective_configured: false, health: {} },
          catalog: { using_fallback: true, total_models: 170, refresh_status: 'not_refreshed' }, endpoints: {}, runtime: {}, features: {}
        }
      end

      it 'says so without a number that looks like an emergency, and offers no check of a key that is not there' do
        expect(text(page.at_css('[data-testid="diagnostics-key"]'))).to include('Не задан', 'Ключ не задан. Без него ИИ-агенты не отвечают.')
        expect(text(page.at_css('[data-testid="diagnostics-credits"]'))).to include('Баланс неизвестен')
        expect(text(page.at_css('[data-testid="diagnostics-catalog"]'))).to include('Не загружен', 'встроенный список платформы (170)')
        expect(page.at_css('button[form="ai-check-key-form"]')).to be_nil
        expect(text(page.at_css('[data-testid="catalog-source"]'))).to include('Ключ OpenRouter не задан')
      end
    end
  end

  describe 'the config pages' do
    it 'titles a page with its Russian name and lists the fields with a Russian title, hint and technical name' do
      get '/super_admin/app_config?config=facebook'

      expect(text(page.at_css('h1'))).to eq('Facebook & Messenger')
      card = field('FB_APP_ID')
      expect(text(card.at_css('.admin-field__title'))).to eq('Facebook: ID приложения')
      expect(text(card.at_css('.admin-field__hint'))).to eq('Идентификатор приложения Meta для Messenger.')
      expect(text(card.at_css('.admin-field__key'))).to eq('FB_APP_ID')
      expect(card.at_css('label')['for']).to eq('app_config_FB_APP_ID')
      expect(card.at_css('input#app_config_FB_APP_ID')).to be_present
    end

    it 'covers every field of every page with a Russian title' do
      pages = SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.keys - %w[captain] + %w[general]

      pages.each do |config|
        get "/super_admin/app_config?config=#{config}"

        expect(response).to have_http_status(:ok), config
        expect(response.body).not_to include('translation missing'), config
        page.css('[data-testid="config-fields"] .admin-field__title').each do |title|
          expect(text(title)).to match(/\p{Cyrillic}/), "#{config}: #{text(title)}"
        end
      end
    end

    it 'shows a yes/no setting as «Да» / «Нет» with the stored value chosen' do
      upsert_installation_config('ENABLE_ACCOUNT_SIGNUP', false)

      get '/super_admin/app_config?config=general'

      select = field('ENABLE_ACCOUNT_SIGNUP').at_css('select')
      expect(select.css('option').map { |option| text(option) }).to eq(%w[Да Нет])
      expect(select.at_css('option[selected]')['value']).to eq('false')
      expect(response.body).not_to match(/>True<|>False</)
    end

    it 'shows a secret without its value: «задан», an empty field to replace it, and a reveal button for what is typed' do
      upsert_installation_config('FB_APP_SECRET', 'never-in-the-page-123')

      get '/super_admin/app_config?config=facebook'

      card = field('FB_APP_SECRET')
      expect(text(card.at_css('[data-testid="secret-state"]'))).to eq('Задан')
      expect(card.at_css('input[type="password"]')['value']).to be_nil
      expect(card.at_css('input[type="password"]')['placeholder']).to eq('Задан — оставьте пустым, чтобы не менять')
      expect(card.at_css('button.toggle-password')['data-target']).to eq('app_config_FB_APP_SECRET')
      expect(response.body).not_to include('never-in-the-page-123')
    end

    it 'says «Не задан» for a secret that has no value' do
      InstallationConfig.where(name: 'FB_APP_SECRET').delete_all

      get '/super_admin/app_config?config=facebook'

      expect(text(field('FB_APP_SECRET').at_css('[data-testid="secret-state"]'))).to eq('Не задан')
    end

    it 'never prints any secret of any config page, whatever page it is on' do
      secrets = {}
      SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.each_value do |names|
        names.select { |name| SuperAdmin::InstallationConfigs.secret?(name) }.each_with_index do |name, index|
          secrets[name] = "stored-#{index}-#{SecureRandom.hex(6)}"
          upsert_installation_config(name, secrets[name])
        end
      end
      upsert_installation_config('FIREBASE_CREDENTIALS', 'stored-firebase-credentials-json')
      expect(secrets.size).to be > 10

      (SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.keys + %w[general]).each do |config|
        get '/super_admin/app_config', params: { config: config }

        expect(response).to have_http_status(:ok), config
        expect(response.body).not_to include(*secrets.values, 'stored-firebase-credentials-json'), "#{config} prints a secret"
        expect(page.css('input[type="password"]').filter_map { |input| input['value'] }).to be_empty
      end
    end

    it 'does not print the WhatsApp secrets that are masked' do
      upsert_installation_config('WHATSAPP_APP_SECRET', 'whatsapp-secret-value')

      get '/super_admin/app_config?config=whatsapp_embedded'

      expect(field('WHATSAPP_APP_SECRET').at_css('input[type="password"]')['value']).to be_nil
      expect(response.body).not_to include('whatsapp-secret-value')
    end

    it 'shows a JSON setting as readable text' do
      upsert_installation_config('ACCOUNT_EMAILS_PLAN_LIMITS', { 'startups' => 10 })

      get '/super_admin/app_config?config=email'

      expect(field('ACCOUNT_EMAILS_PLAN_LIMITS').at_css('textarea').text).to include('"startups": 10')
      expect(response.body).not_to include('=&gt;')
    end

    it 'offers the same settings on the community and the enterprise plan' do
      names = lambda do
        get '/super_admin/app_config?config=captain'
        page.css('[name^="app_config["]').pluck('name').sort
      end
      enterprise_names = names.call
      allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
      community_names = names.call

      expect(community_names).to eq(enterprise_names)
      expect(enterprise_names).to include('app_config[CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY]', 'app_config[ACCOUNT_CAPTAIN_TOKENS_LIMIT]')
    end
  end

  describe 'the messages of saving' do
    def alert
      flash[:alert]
    end

    it 'says which page was saved, in Russian' do
      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: '123' } }

      expect(response).to redirect_to(super_admin_app_config_path(config: 'facebook'))
      expect(flash[:notice]).to eq('Настройки «Facebook & Messenger» сохранены.')
    end

    it 'says in the card of the setting, in Russian, that a model is refused, and counts what was refused' do
      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_DEFAULT_MODEL: 'vendor/not-in-catalog' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Nokogiri::HTML(response.body).at_css('.flash-alert').text.squish).to eq('Ничего не сохранено: исправьте 1 настройку, она отмечена красным.')
      message = Nokogiri::HTML(response.body).at_css('[data-error-for="CAPTAIN_DEFAULT_MODEL"]')
      expect(message.text.squish).to include('Модель «vendor/not-in-catalog» не найдена')
    end

    it 'refuses system prompts that are not JSON, in Russian, in the card of the rules' do
      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_SYSTEM_PROMPTS: '{not json' } }

      expect(response).to have_http_status(:unprocessable_entity)
      message = Nokogiri::HTML(response.body).at_css('[data-error-for="CAPTAIN_SYSTEM_PROMPTS"]')
      expect(message.text.squish).to eq('Правила не удалось прочитать. Обновите страницу и повторите.')
    end

    it 'refuses a webhook routing value that is not a JSON object, in Russian' do
      post '/super_admin/app_config?config=whatsapp_embedded', params: { app_config: { WHATSAPP_WEBHOOK_ROUTING_RULES: '["dev"]' } }

      expect(alert).to eq('WhatsApp: правила маршрутизации вебхуков: нужен допустимый JSON-объект.')
    end

    it 'says so in Russian when the key of a check is missing' do
      allow(Llm::OpenRouterKeyHealth).to receive(:configured?).and_return(false)

      post '/super_admin/app_config/refresh_openrouter_key_health'

      expect(alert).to eq('Ключ OpenRouter не задан.')
    end

    it 'queues the check of the key in Russian' do
      allow(Llm::OpenRouterKeyHealth).to receive(:configured?).and_return(true)
      expect(Internal::RefreshOpenRouterKeyHealthJob).to receive(:perform_later)

      post '/super_admin/app_config/refresh_openrouter_key_health'

      expect(flash[:notice]).to eq('Проверка ключа и кредитов OpenRouter поставлена в очередь.')
    end

    %w[missing invalid expired credits_exhausted key_limit_exhausted unavailable].each do |status|
      it "gives a Russian reason when the catalog cannot be refreshed because the key is #{status}" do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(status: status)
        expect(Internal::RefreshOpenRouterModelCatalogJob).not_to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(alert).to match(/\p{Cyrillic}/)
        expect(alert).not_to match(/OpenRouter (API )?key|credits/)
      end
    end

    it 'saves an instance refresh in Russian' do
      allow(Internal::CheckNewVersionsJob).to receive(:perform_now)

      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: 'true') { get '/super_admin/settings/refresh' }

      expect(flash[:notice]).to eq('Статус установки обновлён.')
      expect(Internal::CheckNewVersionsJob).to have_received(:perform_now)
    end

    it 'does nothing, and says so, when the installation did not opt in to the hub of the base' do
      allow(Internal::CheckNewVersionsJob).to receive(:perform_now)

      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: nil) { get '/super_admin/settings/refresh' }

      expect(Internal::CheckNewVersionsJob).not_to have_received(:perform_now)
      expect(flash[:notice]).to eq('Обмен данными с сервером разработчиков основы платформы выключен. Включить его можно только настройкой сервера.')
    end
  end

  describe 'the instance settings page' do
    before { get '/super_admin/settings' }

    it 'shows the version of OneLink and the functions of the platform' do
      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Настройки платформы')
      expect(text(page.at_css('[data-testid="installation-block"] h2'))).to eq('Версия OneLink')
      expect(text(page.at_css('[data-testid="onelink-version"]'))).to eq(SuperAdmin::BuildInfo.version)
      expect(text(page.at_css('[data-testid="onelink-build"]'))).to eq(SuperAdmin::BuildInfo.build)
      expect(page.css('[data-testid="features-block"] [data-feature]').size).to eq(SuperAdmin::FeaturesHelper.available_features.size)
    end

    it 'does not show the identifier the installation has at the hub of the base, nor a button to copy it' do
      expect(response.body).not_to include(ChatwootHub.installation_identifier)
      expect(response.body).not_to match(/Идентификатор установки|data-secret-text|secretField/)
    end

    it 'has no upgrade offer and no mention of editions to buy' do
      expect(response.body).not_to match(/тариф выше|Enterprise|sales@|Перейти на|upgrade/i)
      expect(page.css('a').map { |link| link['href'].to_s }).not_to include(a_string_matching(/chatwoot\.com/))
    end

    it 'links the functions that have a config page to it' do
      link = page.at_css('[data-feature="captain"] a')

      expect(link['href']).to eq('/super_admin/app_config?config=captain')
      expect(text(link)).to eq('Настроить')
    end

    it 'marks a function that is not available as such, without a link' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
      get '/super_admin/settings'

      branding = page.at_css('[data-feature="custom_branding"]')
      expect(branding['data-enabled']).to eq('false')
      expect(text(branding)).to include('Недоступна')
      expect(branding.at_css('a')).to be_nil
    end
  end

  describe 'the pages of integrations the platform does not use' do
    removed = %w[linear notion shopify saml internal]

    # A page that raises «not found» does not commit the session, so every request signs in again
    it 'are not found, and do not show the general settings under their name' do
      removed.each do |config|
        sign_in(super_admin, scope: :super_admin)
        get "/super_admin/app_config?config=#{config}"

        expect(response).to have_http_status(:not_found), "#{config}: #{response.status} #{response.body.first(300)}"
        expect(response.body).not_to include('app_config[ENABLE_ACCOUNT_SIGNUP]'), config
      end
    end

    it 'cannot be saved' do
      removed.each do |config|
        sign_in(super_admin, scope: :super_admin)
        expect { post "/super_admin/app_config?config=#{config}", params: { app_config: { LINEAR_CLIENT_ID: 'x', DASHBOARD_SCRIPTS: '<script>' } } }
          .not_to change(InstallationConfig, :count)

        expect(response).to have_http_status(:not_found), "#{config}: #{response.status} #{response.body.first(300)}"
      end
      expect(InstallationConfig.where(name: %w[LINEAR_CLIENT_ID DASHBOARD_SCRIPTS]).map(&:value)).not_to include('x', '<script>')
    end

    it 'cannot be reached with a list in place of the name' do
      get '/super_admin/app_config', params: { config: %w[general internal] }

      expect(response).to have_http_status(:not_found)
    end

    it 'are not in the menu nor among the functions of the settings page' do
      get '/super_admin/settings'

      removed.each do |config|
        expect(page.css('a').pluck('href')).not_to include("/super_admin/app_config?config=#{config}")
        expect(page.at_css("[data-feature='#{config}']")).to be_nil
      end
      expect(response.body).not_to match(/Linear|Notion|Shopify|SAML/)
    end

    it 'leave every other page as it was' do
      %w[general facebook instagram tiktok whatsapp_embedded google microsoft email slack captain custom_branding].each do |config|
        get "/super_admin/app_config?config=#{config}"

        expect(response).to have_http_status(:ok), config
      end
    end

    it 'keep the code of the integrations: the keys stay in the catalogue of installation parameters' do
      expect(SuperAdmin::InstallationConfigs.known?('LINEAR_CLIENT_ID')).to be(true)
      expect(SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.keys).not_to include('linear', 'notion', 'shopify')
    end
  end
end
