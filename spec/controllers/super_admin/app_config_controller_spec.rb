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

      it 'shows OpenRouter captain config fields and the collapsed diagnostics for enterprise plan' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=captain'

        expect(response).to have_http_status(:success)
        expect(response.body).to include(
          'Ключ OpenRouter',
          'CAPTAIN_OPENROUTER_API_KEY',
          'Адрес OpenRouter',
          'CAPTAIN_OPENROUTER_ENDPOINT',
          'Диагностика OpenRouter',
          'Каталог моделей',
          'Провайдеры',
          'События за 24 часа',
          'Обновить каталог моделей',
          'Проверить ключ и кредиты'
        )
        diagnostics = Nokogiri::HTML(response.body).at_css('details#openrouter-diagnostics')
        expect(diagnostics['open']).to be_nil
      end

      it 'does not render the configured OpenRouter API key value on the captain config page' do
        allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-openrouter-secret-value')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=captain'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Задан — оставьте пустым, чтобы не менять')
        expect(response.body).not_to include('test-openrouter-secret-value')
      end

      it 'does not render configured WhatsApp secrets on the embedded config page' do
        upsert_installation_config('WHATSAPP_APP_SECRET', 'test-whatsapp-app-secret')
        upsert_installation_config('WHATSAPP_WEBHOOK_VERIFY_TOKEN', 'test-whatsapp-verify-token')
        upsert_installation_config('WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN', 'test-public-ingress-token')
        upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_SECRET', 'test-internal-forward-secret')
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/app_config?config=whatsapp_embedded'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Задан — оставьте пустым, чтобы не менять')
        expect(response.body).not_to include(
          'test-whatsapp-app-secret',
          'test-whatsapp-verify-token',
          'test-public-ingress-token',
          'test-internal-forward-secret'
        )
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

      describe 'AI models chosen by the platform' do
        let(:model_config_params) do
          {
            CAPTAIN_DEFAULT_MODEL: 'openai/gpt-6-luna',
            CAPTAIN_AUDIO_TRANSCRIPTION_MODEL: 'openai/gpt-4o-mini-transcribe',
            CAPTAIN_IMAGE_RECOGNITION_MODEL: 'openai/gpt-5.4-mini',
            CAPTAIN_MODERATION_MODEL: 'openai/gpt-oss-safeguard-20b',
            CAPTAIN_CUSTOM_GUARDRAIL_MODEL: 'openai/gpt-6-luna',
            CAPTAIN_OUTCOME_CLASSIFIER_MODEL: 'microsoft/microsoft-decision-1',
            CAPTAIN_LANGUAGE_DETECTION_MODEL: 'openai/gpt-6-luna-decisions',
            CAPTAIN_EMBEDDING_MODEL: 'text-embedding-3-small',
            CAPTAIN_LABEL_SUGGESTION_MODEL: 'gpt-5.4-mini',
            CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: '["openai/gpt-6-luna", " openai/gpt-5.6-luna ", "openai/gpt-6-luna"]'
          }
        end
        let(:model_config_names) { model_config_params.keys.map(&:to_s) }

        before { sign_in(super_admin, scope: :super_admin) }

        it 'lists the model slots and the short list on the AI agents config page' do
          allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

          get '/super_admin/app_config?config=captain'

          expect(response).to have_http_status(:success)
          expect(response.body).to include(*model_config_names, 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')
          expect(response.body).to include('Короткий список моделей для основного агента', 'Модель расшифровки голоса')
          expect(response.body).to include('Модель определения языка клиента')
        end

        it 'lists the same fields on the community plan config page' do
          get '/super_admin/app_config?config=captain'

          expect(response).to have_http_status(:success)
          expect(response.body).to include(*model_config_names)
        end

        it 'saves valid models and a normalized short list' do
          allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

          post '/super_admin/app_config?config=captain', params: { app_config: model_config_params }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')&.value).to eq('openai/gpt-6-luna')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')&.value).to eq('openai/gpt-4o-mini-transcribe')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_IMAGE_RECOGNITION_MODEL')&.value).to eq('openai/gpt-5.4-mini')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_MODERATION_MODEL')&.value).to eq('openai/gpt-oss-safeguard-20b')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL')&.value).to eq('openai/gpt-6-luna')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_OUTCOME_CLASSIFIER_MODEL')&.value).to eq('microsoft/microsoft-decision-1')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')&.value)
            .to eq('["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
        end

        it 'saves the same on the community plan' do
          post '/super_admin/app_config?config=captain', params: { app_config: model_config_params }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')&.value)
            .to eq('["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
        end

        it 'renders both independent slots and saves a changed guardrail model on the enterprise plan' do
          allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
          upsert_installation_config('CAPTAIN_CUSTOM_GUARDRAIL_MODEL', 'openai/gpt-6-luna')
          upsert_installation_config('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'microsoft/microsoft-decision-1')

          get '/super_admin/app_config?config=captain'

          expect(response).to have_http_status(:success)
          expect(response.body).to include(
            'name="app_config[CAPTAIN_CUSTOM_GUARDRAIL_MODEL]"',
            'name="app_config[CAPTAIN_OUTCOME_CLASSIFIER_MODEL]"'
          )

          post '/super_admin/app_config?config=captain',
               params: { app_config: { CAPTAIN_CUSTOM_GUARDRAIL_MODEL: 'openai/gpt-5.6-luna' } }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL')&.value).to eq('openai/gpt-5.6-luna')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_OUTCOME_CLASSIFIER_MODEL')&.value).to eq('microsoft/microsoft-decision-1')
        end

        it 'allows the platform to explicitly select the served dated Decision model for outcomes' do
          post '/super_admin/app_config?config=captain',
               params: { app_config: { CAPTAIN_OUTCOME_CLASSIFIER_MODEL: 'microsoft/microsoft-decision-1-20261009' } }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_OUTCOME_CLASSIFIER_MODEL')&.value)
            .to eq('microsoft/microsoft-decision-1-20261009')
        end

        it 'accepts Decision as the custom guardrail model and retains the outcome setting' do
          upsert_installation_config('CAPTAIN_CUSTOM_GUARDRAIL_MODEL', 'openai/gpt-6-luna')
          upsert_installation_config('CAPTAIN_OUTCOME_CLASSIFIER_MODEL', 'openai/gpt-5.4-mini')

          post '/super_admin/app_config?config=captain',
               params: { app_config: { CAPTAIN_CUSTOM_GUARDRAIL_MODEL: 'microsoft/microsoft-decision-1' } }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL')&.value).to eq('microsoft/microsoft-decision-1')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_OUTCOME_CLASSIFIER_MODEL')&.value).to eq('openai/gpt-5.4-mini')
        end

        it 'clears a model slot and the short list when they are submitted blank' do
          upsert_installation_config('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'openai/gpt-4o-mini-transcribe')
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')

          post '/super_admin/app_config?config=captain',
               params: { app_config: { CAPTAIN_AUDIO_TRANSCRIPTION_MODEL: '', CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: '  ' } }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')&.value).to be_blank
          expect(Llm::Models.configured_model_allowlist).to be_nil
        end

        it 'rejects a short list entry that is not in the model catalog and keeps the old list' do
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')

          post '/super_admin/app_config?config=captain',
               params: { app_config: { CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: '["openai/gpt-6-luna", "vendor/not-in-catalog"]' } }

          expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
          expect(flash[:alert]).to include('vendor/not-in-catalog')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')&.value).to eq('["openai/gpt-6-luna"]')
        end

        it 'rejects a short list that is not a JSON array of model ids' do
          original_value = '["openai/gpt-6-luna","openai/gpt-5.6-luna"]'
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', original_value)

          ['{not json', '{"model": "openai/gpt-6-luna"}', '[1, 2]'].each do |value|
            post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: value } }

            expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
            expect(flash[:alert]).to include('JSON')
          end
          expect(InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')&.value).to eq(original_value)
        end

        it 'rejects a short list that is not short' do
          limit = Llm::InstallationModelConfig::ALLOWLIST_LIMIT
          models = (1..(limit + 1)).map { |index| "vendor/model-#{index}" }

          post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: models.to_json } }

          expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
          expect(flash[:alert]).to include(limit.to_s)
        end

        it 'rejects a short list without the default AI agent model' do
          upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
          upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna","openai/gpt-5.6-luna"]')
          default_model = Llm::Config.model_for(feature: 'assistant', fallback: nil)

          post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_ASSISTANT_MODEL_ALLOWLIST: '["openai/gpt-5.6-luna"]' } }

          expect(default_model).to eq('openai/gpt-6-luna')
          expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
          expect(flash[:alert]).to include(default_model)
          expect(Llm::Models.configured_model_allowlist).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
        end

        it 'lets the platform move every model of the default at once and back to Luna 5.6, which stays on the short list' do
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna","openai/gpt-5.6-luna"]')

          post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_DEFAULT_MODEL: 'openai/gpt-5.6-luna' } }

          expect(response).to redirect_to(super_admin_settings_path)
          expect(InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')&.value).to eq('openai/gpt-5.6-luna')
          expect(Llm::Config.installation_default_model).to eq('openai/gpt-5.6-luna')
        end

        it 'rejects a default model that is unknown, unfit for the agent, editor and copilot, or outside the short list' do
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')
          upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')

          ['vendor/not-in-catalog', 'openai/gpt-4o-mini-transcribe', 'openai/gpt-5.6-luna'].each do |value|
            post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_DEFAULT_MODEL: value } }

            expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
            expect(flash[:alert]).to include('CAPTAIN_DEFAULT_MODEL')
          end
          expect(InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')&.value).to eq('openai/gpt-6-luna')
        end

        it 'rejects a model slot whose model is unknown or unfit for the feature' do
          upsert_installation_config('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'openai/gpt-4o-mini-transcribe')
          upsert_installation_config('CAPTAIN_IMAGE_RECOGNITION_MODEL', 'openai/gpt-5.4-mini')

          post '/super_admin/app_config?config=captain', params: {
            app_config: { CAPTAIN_AUDIO_TRANSCRIPTION_MODEL: 'openai/gpt-5.4', CAPTAIN_IMAGE_RECOGNITION_MODEL: 'vendor/not-in-catalog' }
          }

          expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
          expect(flash[:alert]).to include('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', 'CAPTAIN_IMAGE_RECOGNITION_MODEL')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL')&.value).to eq('openai/gpt-4o-mini-transcribe')
          expect(InstallationConfig.find_by(name: 'CAPTAIN_IMAGE_RECOGNITION_MODEL')&.value).to eq('openai/gpt-5.4-mini')
        end
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

      it 'keeps existing WhatsApp secrets when their masked fields are submitted blank' do
        upsert_installation_config('WHATSAPP_APP_SECRET', 'test-whatsapp-app-secret')
        upsert_installation_config('WHATSAPP_WEBHOOK_VERIFY_TOKEN', 'test-whatsapp-verify-token')
        upsert_installation_config('WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN', 'test-public-ingress-token')
        upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_SECRET', 'test-internal-forward-secret')
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=whatsapp_embedded', params: {
          app_config: {
            WHATSAPP_APP_SECRET: '',
            WHATSAPP_WEBHOOK_VERIFY_TOKEN: '',
            WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN: '',
            WHATSAPP_WEBHOOK_FORWARD_SECRET: ''
          }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'WHATSAPP_APP_SECRET')&.value).to eq('test-whatsapp-app-secret')
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_VERIFY_TOKEN')&.value).to eq('test-whatsapp-verify-token')
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN')&.value).to eq('test-public-ingress-token')
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_FORWARD_SECRET')&.value).to eq('test-internal-forward-secret')
      end

      it 'normalizes WhatsApp webhook routing objects before persistence' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=whatsapp_embedded', params: {
          app_config: {
            WHATSAPP_WEBHOOK_ROUTING_RULES: '{ "123456": ["dev"] }',
            WHATSAPP_WEBHOOK_FORWARD_TARGETS: <<~JSON.squish
              {
                "dev": "https://dev.one-link.kz/webhooks/whatsapp",
                "widget": "https://widget.one-link.kz/webhooks/meta/whatsapp"
              }
            JSON
          }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_ROUTING_RULES')&.value)
          .to eq('{"123456":["dev"]}')
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_FORWARD_TARGETS')&.value)
          .to eq(
            '{"dev":"https://dev.one-link.kz/webhooks/whatsapp",' \
            '"widget":"https://medelement.one-link.kz/webhooks/meta/whatsapp"}'
          )
      end

      it 'rejects a WhatsApp webhook routing value that is not a JSON object' do
        upsert_installation_config('WHATSAPP_WEBHOOK_ROUTING_RULES', '{"123456":["dev"]}')
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=whatsapp_embedded', params: {
          app_config: { WHATSAPP_WEBHOOK_ROUTING_RULES: '["dev"]' }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_ROUTING_RULES')&.value)
          .to eq('{"123456":["dev"]}')
      end

      it 'rejects non-canonical WhatsApp webhook forward targets' do
        canonical_target = {
          dev: 'https://dev.one-link.kz/webhooks/whatsapp',
          widget: 'https://medelement.one-link.kz/webhooks/meta/whatsapp'
        }.to_json
        upsert_installation_config('WHATSAPP_WEBHOOK_FORWARD_TARGETS', canonical_target)
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=whatsapp_embedded', params: {
          app_config: { WHATSAPP_WEBHOOK_FORWARD_TARGETS: '{"dev":"https://127.0.0.1/webhooks/whatsapp"}' }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_FORWARD_TARGETS')&.value).to eq(canonical_target)
      end

      it 'rejects invalid WhatsApp webhook route keys and destinations' do
        existing_rules = '{"123456":["dev"]}'
        upsert_installation_config('WHATSAPP_WEBHOOK_ROUTING_RULES', existing_rules)
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=whatsapp_embedded', params: {
          app_config: { WHATSAPP_WEBHOOK_ROUTING_RULES: '{"not-a-waba":["internal"]}' }
        }

        expect(response).to have_http_status(:found)
        expect(InstallationConfig.find_by(name: 'WHATSAPP_WEBHOOK_ROUTING_RULES')&.value).to eq(existing_rules)
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
        expect(flash[:notice]).to eq('Обновление каталога моделей поставлено в очередь. Состояние и изменения появятся после его завершения.')
      end

      it 'does not queue the refresh job when cached OpenRouter key health is invalid' do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(status: 'invalid')
        expect(Internal::RefreshOpenRouterModelCatalogJob).not_to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
        expect(flash[:alert]).to eq('Ключ OpenRouter недействителен. Проверьте ключ перед обновлением каталога.')
      end

      it 'does not queue the refresh job when the global OpenRouter key is missing' do
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(false)
        expect(Internal::RefreshOpenRouterModelCatalogJob).not_to receive(:perform_later)

        post '/super_admin/app_config/refresh_openrouter_models'

        expect(response).to redirect_to(super_admin_app_config_path(config: 'captain'))
        expect(flash[:alert]).to eq('Ключ OpenRouter не задан.')
      end
    end
  end

  # A secret that is left empty is not changed (the page never shows it, so empty means «do not change»), and every
  # save leaves an entry in the audit log that names the setting and never holds the value of a secret.
  describe 'saving secrets and the audit log of the settings' do
    before { sign_in(super_admin, scope: :super_admin) }

    def setting_audits(name = nil)
      scope = Audited::Audit.where(auditable_type: 'InstallationConfig', action: 'update_setting')
      scope = scope.where(auditable_id: InstallationConfig.find_by!(name: name).id) if name
      scope.order(:id)
    end

    it 'keeps the stored secret when the field is sent empty, for any secret and not only the platform keys' do
      upsert_installation_config('FB_APP_SECRET', 'stored-facebook-secret')
      upsert_installation_config('IG_VERIFY_TOKEN', 'stored-instagram-token')

      expect do
        post '/super_admin/app_config?config=facebook',
             params: { app_config: { FB_APP_ID: 'new-id', FB_APP_SECRET: '', IG_VERIFY_TOKEN: '' } }
      end.not_to change { InstallationConfig.where(name: %w[FB_APP_SECRET IG_VERIFY_TOKEN]).map(&:serialized_value) }

      expect(InstallationConfig.find_by!(name: 'FB_APP_SECRET').value).to eq('stored-facebook-secret')
      expect(InstallationConfig.find_by!(name: 'IG_VERIFY_TOKEN').value).to eq('stored-instagram-token')
      expect(InstallationConfig.find_by!(name: 'FB_APP_ID').value).to eq('new-id')
    end

    it 'does not create a row for an empty secret that was never set' do
      InstallationConfig.where(name: 'FB_APP_SECRET').delete_all

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_SECRET: '' } }

      expect(InstallationConfig.where(name: 'FB_APP_SECRET')).to be_empty
      expect(setting_audits).to be_empty
    end

    it 'replaces a secret when a new value is typed, and the audit log says «changed» without any value' do
      upsert_installation_config('FB_APP_SECRET', 'old-facebook-secret')

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_SECRET: 'new-facebook-secret' } }

      expect(InstallationConfig.find_by!(name: 'FB_APP_SECRET').value).to eq('new-facebook-secret')
      audit = setting_audits('FB_APP_SECRET').last
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('name' => 'FB_APP_SECRET', 'value' => 'changed')
      expect(audit.audited_changes.to_s).not_to include('old-facebook-secret', 'new-facebook-secret')
    end

    it 'writes the old and the new value of an ordinary setting' do
      upsert_installation_config('FB_APP_ID', 'old-id', locked: false)

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'new-id' } }

      expect(setting_audits('FB_APP_ID').last.audited_changes).to eq('name' => 'FB_APP_ID', 'value' => %w[old-id new-id])
    end

    it 'writes one entry for each setting that changed and none for a setting that did not' do
      upsert_installation_config('FB_APP_ID', 'same-id', locked: false)
      upsert_installation_config('FACEBOOK_API_VERSION', 'v1', locked: false)

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'same-id', FACEBOOK_API_VERSION: 'v2' } }

      expect(setting_audits.map { |audit| audit.audited_changes['name'] }).to eq(['FACEBOOK_API_VERSION'])
    end

    it 'writes an entry for a setting that is saved for the first time' do
      InstallationConfig.where(name: 'FB_APP_ID').delete_all

      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'first-id' } }

      expect(setting_audits.last.audited_changes).to eq('name' => 'FB_APP_ID', 'value' => ['', 'first-id'])
    end

    it 'cuts a long value in the audit log' do
      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'x' * 1000 } }

      expect(setting_audits.last.audited_changes['value'].last.length).to eq(SuperAdmin::AppConfigsController::AUDITED_VALUE_LIMIT)
    end

    it 'treats every secret of the OpenRouter key like any other: empty keeps it, typed replaces it, the log holds no key' do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'sk-old-key')

      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_OPENROUTER_API_KEY: '' } }
      expect(InstallationConfig.find_by!(name: 'CAPTAIN_OPENROUTER_API_KEY').value).to eq('sk-old-key')

      post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_OPENROUTER_API_KEY: 'sk-new-key' } }
      expect(InstallationConfig.find_by!(name: 'CAPTAIN_OPENROUTER_API_KEY').value).to eq('sk-new-key')
      expect(setting_audits('CAPTAIN_OPENROUTER_API_KEY').last.audited_changes.to_s).not_to include('sk-old-key', 'sk-new-key')
    end

    it 'shows the audit entry of a setting by its Russian names in the audit log' do
      post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'logged-id' } }

      get '/super_admin/audits'

      expect(response.body).to include('Изменение настройки', 'Параметр системы')
      expect(response.body).not_to include('translation missing')
    end
  end
end
