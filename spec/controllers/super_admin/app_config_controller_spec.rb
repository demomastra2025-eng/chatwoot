require 'rails_helper'

RSpec.describe 'Super Admin Application Config API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/app_config' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/app_config'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      let!(:config) do
        InstallationConfig.find_or_initialize_by(name: 'FB_APP_ID').tap do |installation_config|
          installation_config.value = 'TESTVALUE'
          installation_config.locked = false
          installation_config.save!
        end
      end

      it 'shows the app_config page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/app_config?config=facebook'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(config.value)
      end

      it 'shows OpenRouter captain config fields and diagnostics for enterprise plan' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=captain'

        expect(response).to have_http_status(:success)
        expect(response.body).to include(
          'OpenRouter API Key',
          'CAPTAIN_OPENROUTER_API_KEY',
          'OpenRouter API Endpoint',
          'CAPTAIN_OPENROUTER_ENDPOINT',
          'OpenRouter diagnostics',
          'Catalog freshness',
          'Catalog diff',
          'Endpoint diff',
          'Runtime telemetry',
          'Runtime top signals',
          'Workspace policy',
          'Feature guardrails',
          'policy: cache',
          'Model eligibility samples',
          'Queue OpenRouter Catalog Refresh'
        )
      end

      it 'does not render the configured OpenRouter API key value on the captain config page' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-openrouter-secret-value')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=captain'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Configured — leave blank to keep current key')
        expect(response.body).not_to include('test-openrouter-secret-value')
      end

      it 'does not expose legacy direct-provider Captain key fields in Super Admin config' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=captain'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('CAPTAIN_OPENROUTER_API_KEY')
        expect(response.body).not_to include('CAPTAIN_OPEN_AI_API_KEY')
        expect(response.body).not_to include('CAPTAIN_ANTHROPIC_API_KEY')
        expect(response.body).not_to include('CAPTAIN_GEMINI_API_KEY')
      end
    end
  end

  describe 'POST /super_admin/app_config' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        post '/super_admin/app_config', params: { app_config: { TESTKEY: 'TESTVALUE' } }
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an aunthenticated super admin' do
      it 'shows the app_config page' do
        sign_in(super_admin, scope: :super_admin)
        post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'FB_APP_ID' } }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(super_admin_settings_path)

        config = GlobalConfig.get('FB_APP_ID')
        expect(config['FB_APP_ID']).to eq('FB_APP_ID')
      end

      it 'persists captain system prompts from super admin' do
        sign_in(super_admin, scope: :super_admin)
        post '/super_admin/app_config?config=captain', params: {
          app_config: {
            CAPTAIN_SYSTEM_PROMPTS: [
              {
                id: 'stay_within_scope',
                type: 'system',
                group: 'Strict rules',
                content: 'Use the installation-wide scope rule.',
                slot: nil
              }
            ].to_json
          }
        }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(super_admin_settings_path)
        expect(InstallationConfig.find_by(name: 'CAPTAIN_SYSTEM_PROMPTS')&.value).to eq(
          [
            {
              'id' => 'stay_within_scope',
              'type' => 'system',
              'group' => 'Strict rules',
              'content' => 'Use the installation-wide scope rule.',
              'slot' => nil
            }
          ]
        )
      end

      it 'persists OpenRouter provider config and refreshes LLM runtime config on enterprise plan' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        sign_in(super_admin, scope: :super_admin)
        expect(Llm::Config).to receive(:reset!).ordered
        expect(Llm::Config).to receive(:initialize!).ordered

        post '/super_admin/app_config?config=captain', params: {
          app_config: {
            CAPTAIN_OPENROUTER_API_KEY: '[REDACTED]',
            CAPTAIN_OPENROUTER_ENDPOINT: 'https://openrouter.example/api/v1'
          }
        }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(super_admin_settings_path)
        expect(InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.value).to eq('[REDACTED]')
        expect(InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_ENDPOINT')&.value).to eq('https://openrouter.example/api/v1')
      end

      it 'keeps the existing OpenRouter key when the masked secret field is submitted blank' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-openrouter-secret-value')
        sign_in(super_admin, scope: :super_admin)
        allow(Llm::Config).to receive(:reset!)
        allow(Llm::Config).to receive(:initialize!)

        post '/super_admin/app_config?config=captain', params: {
          app_config: {
            CAPTAIN_OPENROUTER_API_KEY: '',
            CAPTAIN_OPENROUTER_ENDPOINT: 'https://openrouter.example/api/v1'
          }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.value).to eq('test-openrouter-secret-value')
        expect(InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_ENDPOINT')&.value).to eq('https://openrouter.example/api/v1')
      end
    end
  end

  describe 'POST /super_admin/app_config/refresh_openrouter_models' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        post '/super_admin/app_config/refresh_openrouter_models'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before do
        sign_in(super_admin, scope: :super_admin)
      end

      it 'queues the OpenRouter catalog refresh job from the captain config page' do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(status: 'valid')
        expect(Internal::RefreshOpenRouterModelCatalogJob).to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
        expect(flash[:notice]).to include('refresh queued')
      end

      it 'does not queue the refresh job when cached OpenRouter key health is invalid' do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(status: 'invalid')
        expect(Internal::RefreshOpenRouterModelCatalogJob).not_to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
        expect(flash[:alert]).to include('OpenRouter API key is invalid')
      end

      it 'does not queue the refresh job when the global OpenRouter key is missing' do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(false)
        expect(Internal::RefreshOpenRouterModelCatalogJob).not_to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
        expect(flash[:alert]).to eq('OpenRouter API key is not configured.')
      end
    end
  end
end
