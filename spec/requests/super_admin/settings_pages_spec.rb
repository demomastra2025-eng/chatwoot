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

  def slot(key)
    page.at_css(%([data-testid="ai-models-form"] [data-config="#{key}"]))
  end

  def field(key)
    page.at_css(%([data-testid="config-fields"] [data-config="#{key}"]))
  end

  describe 'the AI models page' do
    let(:groups) do
      {
        'agent' => 'Основная модель агентов',
        'safety' => 'Модерация и защита',
        'knowledge' => 'Поиск по базе знаний',
        'voice' => 'Голос и расшифровка',
        'images' => 'Картинки',
        'classifiers' => 'Классификаторы и служебные модели',
        'connection' => 'Подключение и лимиты',
        'prompts' => 'Системные промпты'
      }
    end

    before { get '/super_admin/app_config?config=captain' }

    it 'is titled «Модели ИИ» and has no translation gaps' do
      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Модели ИИ')
      expect(response.body).not_to include('translation missing')
    end

    it 'groups the cards by purpose, in the order of the page' do
      headings = page.css('[data-testid="ai-models-form"] section[data-testid^="ai-group-"] h2').map { |heading| text(heading) }

      expect(headings).to eq(groups.values)
    end

    it 'puts every setting of the page in exactly one card with its own control' do
      keys = SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS

      keys.each do |key|
        expect(page.css(%([data-testid="ai-models-form"] [data-config="#{key}"])).size).to eq(1), "card of #{key}"
        expect(page.css(%([name="app_config[#{key}]"])).size).to eq(1), "control of #{key}"
      end
    end

    it 'gives every card a Russian title and keeps the technical name as a small caption' do
      card = slot('CAPTAIN_DEFAULT_MODEL')

      expect(text(card.at_css('.admin-slot__title'))).to eq('Модель ИИ по умолчанию')
      expect(text(card.at_css('.admin-field__key'))).to eq('CAPTAIN_DEFAULT_MODEL')
      expect(text(slot('CAPTAIN_OPENROUTER_API_KEY').at_css('.admin-slot__title'))).to eq('Ключ OpenRouter')
    end

    it 'keeps English display titles out of the cards' do
      titles = page.css('.admin-slot__title').map { |node| text(node) }

      expect(titles).not_to include('OpenRouter API Key', 'AI Agent Global System Prompt', 'AI Tokens Limit')
    end

    it 'does not offer the legacy direct-provider keys' do
      expect(response.body).not_to include('CAPTAIN_OPEN_AI_API_KEY', 'CAPTAIN_ANTHROPIC_API_KEY', 'CAPTAIN_GEMINI_API_KEY')
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

    it 'says «Задано» and shows the value in force for a setting the platform has set' do
      card = slot('CAPTAIN_DEFAULT_MODEL')

      expect(card['data-source']).to eq('set')
      expect(text(card.at_css('[data-testid="slot-source"]'))).to eq('Задано')
      facts = text(card.at_css('[data-testid="slot-facts"]'))
      expect(facts).to include('Действует', 'openai/gpt-5.6-luna', 'По умолчанию', Llm::Config::DEFAULT_MODEL)
      expect(card.at_css('input[name="app_config[CAPTAIN_DEFAULT_MODEL]"]')['value']).to eq('openai/gpt-5.6-luna')
    end

    it 'says «По умолчанию» and names the built-in model for a blank slot' do
      card = slot('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')

      expect(card['data-source']).to eq('default')
      expect(text(card.at_css('[data-testid="slot-source"]'))).to eq('По умолчанию')
      expect(text(card.at_css('[data-testid="slot-facts"]'))).to include('Действует по умолчанию', 'openai/gpt-4o-mini-transcribe')
      expect(card.at_css('input')['placeholder']).to eq('openai/gpt-4o-mini-transcribe')
    end

    it 'says a blank slot follows the default model of the installation when that is its built-in value' do
      facts = text(slot('CAPTAIN_IMAGE_RECOGNITION_MODEL').at_css('[data-testid="slot-facts"]'))

      expect(facts).to include('openai/gpt-5.6-luna', 'как у «Модели ИИ по умолчанию»')
    end

    it 'lists the models of the short list one by one' do
      chips = slot('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').css('.admin-chip').map { |chip| text(chip) }

      expect(chips).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
    end
  end

  describe 'secrets on the AI models page' do
    it 'shows only that a key is set, never the key' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-test-openrouter-secret')
      upsert_installation_config('CAPTAIN_FIRECRAWL_API_KEY', 'fc-test-firecrawl-secret')

      get '/super_admin/app_config?config=captain'

      card = slot('CAPTAIN_OPENROUTER_API_KEY')
      expect(text(card.at_css('[data-testid="slot-source"]'))).to eq('Задан')
      input = card.at_css('input[type="password"]')
      expect(input['value']).to be_nil
      expect(input['placeholder']).to eq('Задан — оставьте пустым, чтобы не менять')
      expect(response.body).not_to include('sk-test-openrouter-secret', 'fc-test-firecrawl-secret')
    end

    it 'says «Не задан» for a key that is missing' do
      InstallationConfig.where(name: 'CAPTAIN_FIRECRAWL_API_KEY').delete_all

      get '/super_admin/app_config?config=captain'

      expect(text(slot('CAPTAIN_FIRECRAWL_API_KEY').at_css('[data-testid="slot-source"]'))).to eq('Не задан')
    end
  end

  describe 'the diagnostics of OpenRouter' do
    let(:diagnostics) do
      {
        key_status: { effective_configured: true, global_configured: true, account_configured: false,
                      health: { status: 'credits_exhausted', checked_at: '2026-10-15T12:05:09Z', key: { key_type: 'inference' },
                                credits: { status: 'management_key_required' } } },
        catalog: { refresh_status: 'success', source: 'openrouter_api', last_refreshed_at: '2026-10-15T12:05:09Z', total_models: 1200,
                   counts_by_type: { chat: 1000, embedding: 20 }, stale_models: 2, disabled_models: 0, last_refresh_diff: {} },
        endpoints: { refresh_status: 'running', total_endpoints: 3400, providers: %w[azure openai] },
        runtime: { total_events: 10, request_count: 8, error_count: 1, provider_failure_count: 0, estimated_cost: 0.5 },
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

    it 'is collapsed and titled «Диагностика OpenRouter»' do
      expect(block['open']).to be_nil
      expect(text(block.at_css('summary'))).to include('Диагностика OpenRouter')
    end

    it 'keeps the two actions' do
      forms = block.css('form').pluck('action')

      expect(forms).to contain_exactly('/super_admin/app_config/refresh_openrouter_key_health?config=captain',
                                       '/super_admin/app_config/refresh_openrouter_models?config=captain')
      expect(text(block)).to include('Проверить ключ и кредиты', 'Обновить каталог моделей')
    end

    it 'names the statuses in Russian instead of showing their codes' do
      expect(text(block.at_css('[data-testid="diagnostics-key"]'))).to include('Кредиты закончились', 'тип: inference')
      expect(text(block.at_css('[data-testid="diagnostics-credits"]'))).to include('Нужен management-ключ', 'нужен management-ключ')
      expect(text(block.at_css('[data-testid="diagnostics-catalog"]'))).to include('Обновлён', 'API OpenRouter', 'чат: 1000', 'эмбеддинги: 20')
      expect(text(block.at_css('[data-testid="diagnostics-providers"]'))).to include('Обновляется', 'azure, openai')
      expect(text(block)).not_to match(/credits_exhausted|management_key_required|openrouter_api/)
    end

    it 'shows the models of a function under its Russian name' do
      feature = block.at_css('[data-feature="assistant"]')

      expect(text(feature)).to include('Основной агент', 'Доступно моделей: 7')
    end

    it 'shows moments in Astana time and numbers with a space between thousands' do
      expect(text(block)).to include('15.10.2026 17:05', '1 200')
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

    it 'shows a secret in a password field with a reveal button' do
      upsert_installation_config('FB_APP_SECRET', 'visible-in-a-password-field')

      get '/super_admin/app_config?config=facebook'

      card = field('FB_APP_SECRET')
      expect(card.at_css('input[type="password"]')['value']).to eq('visible-in-a-password-field')
      expect(card.at_css('button.toggle-password')['data-target']).to eq('app_config_FB_APP_SECRET')
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

      expect(response).to redirect_to(super_admin_settings_path)
      expect(flash[:notice]).to eq('Настройки «Facebook & Messenger» сохранены.')
    end

    it 'names the setting with its Russian title and technical name when a model is refused' do
      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_DEFAULT_MODEL: 'vendor/not-in-catalog' } }

      expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
      expect(alert).to include('Модель ИИ по умолчанию (CAPTAIN_DEFAULT_MODEL): модель «vendor/not-in-catalog» не найдена')
    end

    it 'refuses system prompts that are not JSON, in Russian' do
      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_SYSTEM_PROMPTS: '{not json' } }

      expect(alert).to eq('Системные промпты платформы должны быть корректным JSON.')
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

      get '/super_admin/settings/refresh'

      expect(flash[:notice]).to eq('Статус установки обновлён.')
    end
  end

  describe 'the instance settings page' do
    before { get '/super_admin/settings' }

    it 'shows the identifier of the installation and the functions of the platform' do
      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Настройки инстанса')
      expect(page.at_css('[data-testid="installation-block"] [data-secret-text]')['data-secret-text']).to eq(ChatwootHub.installation_identifier)
      expect(page.css('[data-testid="features-block"] [data-feature]').size).to eq(SuperAdmin::FeaturesHelper.available_features.size)
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
end
