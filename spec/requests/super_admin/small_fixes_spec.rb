# frozen_string_literal: true

require 'rails_helper'

# Small fixes of the super admin: Russian text where English or a raw key was shown, the door of the demo data closed
# when its button is hidden, a settings page that returns to itself after saving.
RSpec.describe 'Super Admin small fixes', type: :request do
  include ActiveJob::TestHelper

  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Аккаунт Север') }

  # Not memoized: some examples open several pages in a row
  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  before do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
    sign_in(super_admin, scope: :super_admin)
  end

  describe 'the way back to the operator app' do
    it 'has a tooltip in Russian' do
      get '/super_admin'

      link = page.css('nav a').find { |anchor| text(anchor) == 'Кабинет оператора' }
      expect(link['title']).to eq('Рабочее место оператора: диалоги, контакты и отчёты')
      expect(response.body).not_to include('Agent Dashboard')
    end
  end

  describe 'the prompt builder of the AI models page' do
    before { get '/super_admin/app_config?config=captain' }

    it 'starts a new prompt without a group, and says in Russian what the empty group means' do
      expect(response.body).not_to include('Strict rules')
      group = page.at_css('#captain-system-prompts-builder template [data-field="group"]')
      expect(group['placeholder']).to eq('Пусто — «Строгие правила»')
    end

    it 'explains the slot in Russian instead of a bare key as the placeholder' do
      slot = page.at_css('#captain-system-prompts-builder template [data-field="slot"]')
      expect(slot['placeholder']).to eq('Необязательно')
      expect(text(slot.parent)).to include('Код места в промпте агента, например assistant_system_context.')
    end
  end

  describe 'the secret fields of the settings pages' do
    it 'name the field in the label of their reveal button, and say whether the value is shown' do
      get '/super_admin/app_config?config=facebook'

      button = page.at_css('button.toggle-password[data-target="app_config_FB_APP_SECRET"]')
      expect(button['aria-label']).to start_with('Показать или скрыть значение: ')
      expect(button['aria-label']).to include(SuperAdmin::AppConfigLabels.title('FB_APP_SECRET'))
      expect(button['aria-pressed']).to eq('false')
      expect(button['aria-controls']).to eq('app_config_FB_APP_SECRET')
    end

    it 'load no script of their own: the reveal script is part of the page' do
      get '/super_admin/app_config?config=facebook'

      expect(response.body).not_to include('secretField')
      expect(Rails.root.join('app/assets/javascripts/secretField.js')).not_to exist
    end
  end

  describe 'the WhatsApp quick connection' do
    it 'has a Russian name in the menu, on its page and among the functions' do
      get '/super_admin/app_config?config=whatsapp_embedded'
      expect(text(page.at_css('h1'))).to eq('WhatsApp: быстрое подключение')
      expect(response.body).not_to include('WhatsApp Embedded')

      get '/super_admin/settings'
      expect(text(page.at_css('[data-feature="whatsapp_embedded"] h3'))).to eq('WhatsApp: быстрое подключение')
      expect(response.body).not_to include('WhatsApp Embedded')
    end
  end

  describe 'saving a settings page' do
    it 'returns to the same page, with the message' do
      post '/super_admin/app_config?config=slack', params: { app_config: { SLACK_CLIENT_ID: 'client-id' } }

      expect(response).to redirect_to('/super_admin/app_config?config=slack')
      follow_redirect!
      expect(text(page.at_css('.flashes'))).to include('Настройки «Slack» сохранены.')
    end

    it 'returns to the general settings after saving them' do
      post '/super_admin/app_config', params: { app_config: { WEBHOOK_TIMEOUT: '7' } }

      expect(response).to redirect_to('/super_admin/app_config?config=general')
    end

    it 'returns to the page where the values were refused' do
      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_DEFAULT_MODEL: 'vendor/not-in-catalog' } }

      expect(response).to redirect_to('/super_admin/app_config?config=captain')
    end
  end

  describe 'the chips of the AI analytics' do
    let(:moment) { Time.utc(2026, 10, 15, 12, 5, 9) }
    let(:report) do
      {
        date_range: (moment - 30.days)..moment,
        snapshot: {
          total_events: 10, request_count: 5, error_count: 0, total_estimated_cost: 1.0, last_event_at: moment,
          by_feature: { 'captain_agent' => 7, 'label_suggestion' => 2, 'agent_reply_v9' => 1 },
          by_model: { 'openai/gpt-6-luna' => 9, 'vendor/unknown-model' => 1 },
          by_provider: { 'openrouter' => 10, 'someone' => 1 }
        },
        top_accounts: []
      }
    end

    before do
      allow(Llm::Monitoring::FleetSnapshot).to receive(:new).and_return(instance_double(Llm::Monitoring::FleetSnapshot, call: report))
      allow(Llm::Models).to receive(:model_config).and_call_original
      allow(Llm::Models).to receive(:model_config).with('openai/gpt-6-luna').and_return({ 'display_name' => 'GPT-6 Luna' })
      allow(Llm::Models).to receive(:model_config).with('vendor/unknown-model').and_return(nil)
      allow(Llm::Models).to receive(:provider_config).with('openrouter').and_return({ 'display_name' => 'OpenRouter' })
      allow(Llm::Models).to receive(:provider_config).with('someone').and_return(nil)
      get '/super_admin/captain_observability'
    end

    it 'name the functions in Russian and leave a key nobody described as it is' do
      chips = text(page.at_css('[data-testid="ai-spread-features"]'))

      expect(chips).to include('Основной агент (7)', 'Подсказки меток (2)', 'agent_reply_v9 (1)')
      expect(chips).not_to include('captain_agent', 'label_suggestion')
    end

    it 'show the display name of a model and of a provider' do
      expect(text(page.at_css('[data-testid="ai-spread-models"]'))).to include('GPT-6 Luna (9)', 'vendor/unknown-model (1)')
      expect(text(page.at_css('[data-testid="ai-spread-providers"]'))).to include('OpenRouter (10)', 'someone (1)')
    end
  end

  describe 'demo data' do
    let(:card) { "/super_admin/accounts/#{account.id}" }

    def seed_forms = page.css('form').select { |form| form['action'] == "#{card}/seed" }

    describe Seeders::Seeding do
      it 'reads the switch as a boolean' do
        {
          'true' => true, '1' => true, 'TRUE' => true, 'false' => false, 'FALSE' => false, '0' => false, 'off' => false, '' => false
        }.each do |value, expected|
          with_modified_env ENABLE_ACCOUNT_SEEDING: value do
            expect(described_class.enabled?).to be(expected), "ENABLE_ACCOUNT_SEEDING=#{value.inspect}"
          end
        end
      end

      it 'is on outside production and off in production when nothing is set' do
        with_modified_env ENABLE_ACCOUNT_SEEDING: nil do
          allow(Rails.env).to receive(:production?).and_return(false)
          expect(described_class.enabled?).to be(true)

          allow(Rails.env).to receive(:production?).and_return(true)
          expect(described_class.enabled?).to be(false)
        end
      end
    end

    it 'offers the button where the installation allows demo data' do
      with_modified_env(ENABLE_ACCOUNT_SEEDING: 'true') { get card }

      expect(seed_forms.size).to eq(1)
    end

    it 'hides the button when the switch says no, however it is spelled' do
      %w[false 0 off].each do |value|
        with_modified_env(ENABLE_ACCOUNT_SEEDING: value) { get card }

        expect(seed_forms).to be_empty, value
      end
    end

    it 'generates the data when it is allowed' do
      with_modified_env ENABLE_ACCOUNT_SEEDING: 'true' do
        expect { post "#{card}/seed" }.to have_enqueued_job(Internal::SeedAccountJob).with(account)
      end

      expect(flash[:notice]).to eq('Запущена генерация демо-данных.')
    end

    it 'refuses the address too when the button is hidden' do
      with_modified_env ENABLE_ACCOUNT_SEEDING: 'false' do
        expect { post "#{card}/seed" }.not_to have_enqueued_job(Internal::SeedAccountJob)
      end

      expect(flash[:alert]).to eq('Демо-данные на этом сервере выключены.')
    end

    it 'is refused by the seeders themselves, which read the switch the same way' do
      with_modified_env ENABLE_ACCOUNT_SEEDING: 'false' do
        expect { Seeders::AccountSeeder.new(account: account) }.to raise_error('Account Seeding is not allowed.')
      end
    end
  end
end
