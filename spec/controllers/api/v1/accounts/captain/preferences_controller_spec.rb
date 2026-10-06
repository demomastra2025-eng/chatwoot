# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Preferences', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/preferences' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'returns captain config' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
      end

      it 'does not serialize expense or budget data with preferences' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).not_to have_key(:usage)
      end

      it 'skips full registry metadata for the controls page' do
        expect(Llm::ModelRegistryService).not_to receive(:runtime_metadata)

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            params: { client_metadata_only: 'true' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:runtime_metadata, :web_access)).to have_key(:configured)
        expect(json_response.dig(:runtime_metadata, :knowledge_indexing)).to have_key(:chunk_size_options)
        expect(json_response.dig(:runtime_metadata, :registry)).to be_nil
      end

      it 'reports text improvement (editor) as on while the account never switched it' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:features, :editor, :enabled)).to be(true)
        expect(json_response.dig(:features, :label_suggestion, :enabled)).to be(false)
      end

      it 'reports text improvement (editor) as off after an admin switched it off' do
        account.update!(captain_features: { 'text_improvement' => false })

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:features, :editor, :enabled)).to be(false)
      end

      it 'reports text improvement as on for a legacy stored editor=false' do
        account.update!(captain_features: { 'editor' => false })

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:features, :editor, :enabled)).to be(true)
      end

      it 'includes only the OpenRouter models the features refer to in the normal Captain settings payload' do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:providers].keys).to contain_exactly(:openrouter)
        expect(json_response[:models].keys).to include(:'openai/gpt-5.4', :'openai/gpt-5.4-mini')
        expect(json_response[:models].values).to all(include(provider: 'openrouter'))
        expect(json_response[:models].keys).not_to include(:'gpt-5.4', :'claude-sonnet-4-6', :'gemini-2.5-pro')
        expect(json_response[:models].size).to be < 20
      end

      it 'includes runtime metadata for resolved providers and feature models' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:runtime_metadata)
        expect(json_response.dig(:runtime_metadata, :providers)).not_to have_key(:openai)
        expect(json_response.dig(:runtime_metadata, :providers, :openrouter)).to include(:configured, :display_name, :models_api)
        expect(json_response.dig(:runtime_metadata, :registry, :openrouter)).to include(:total_models, :using_fallback)
        expect(json_response.dig(:runtime_metadata, :features, :assistant)).to include(:selected_model, :provider)
      end

      context 'with a large OpenRouter catalog' do
        let(:chat_capabilities) { %w[text_input text_output structured_output tool_calling tool_choice] }
        let(:catalog) do
          bulk_models = (1..250).to_h do |index|
            ["vendor/model-#{index}", { 'provider' => 'openrouter', 'display_name' => "Model #{index}", 'type' => 'chat',
                                        'capabilities' => chat_capabilities }]
          end
          bulk_models.merge(
            'openai/gpt-5.4' => { 'provider' => 'openrouter', 'display_name' => 'GPT 5.4', 'type' => 'chat',
                                  'capabilities' => chat_capabilities },
            'openai/gpt-5.4-mini' => { 'provider' => 'openrouter', 'display_name' => 'GPT 5.4 mini', 'type' => 'chat',
                                       'capabilities' => chat_capabilities }
          )
        end

        before do
          upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
          allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(catalog)
        end

        def fetch_preferences
          get "/api/v1/accounts/#{account.id}/captain/preferences",
              headers: admin.create_new_auth_token,
              as: :json
          expect(response).to have_http_status(:success)
        end

        it 'sends only the platform short list for the main agent model, never the catalog' do
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.4", "openai/gpt-5.4-mini"]')

          fetch_preferences

          assistant_models = json_response.dig(:features, :assistant, :models)
          expect(assistant_models.pluck(:id)).to include('openai/gpt-5.4', 'openai/gpt-5.4-mini')
          expect(assistant_models.pluck(:id).size).to be <= 4
          expect(json_response.dig(:features, :assistant, :diagnostic_models)).to eq([])
          expect(json_response[:models].keys.size).to be < 20
          expect(response.body).not_to include('vendor/model-')
        end

        it 'falls back to the built-in short list while the platform has not curated one' do
          fetch_preferences

          ids = json_response.dig(:features, :assistant, :models).pluck(:id)
          expect(ids).to all(satisfy { |id| Llm::Models::DEFAULT_CURATED_MODELS.include?(id) })
          expect(response.body).not_to include('vendor/model-')
        end

        it 'lists the models of the recognition features only as the one chosen by the platform' do
          upsert_installation_config('CAPTAIN_IMAGE_RECOGNITION_MODEL', 'openai/gpt-5.4-mini')

          fetch_preferences

          %i[audio_transcription image_recognition help_center_search moderation label_suggestion].each do |feature_key|
            feature = json_response.dig(:features, feature_key)
            expect(feature[:managed]).to be(true)
            expect(feature[:models].pluck(:id).size).to be <= 1
          end
          expect(json_response.dig(:features, :image_recognition, :selected)).to eq('openai/gpt-5.4-mini')
          expect(json_response.dig(:features, :assistant, :managed)).to be(false)
        end

        it 'keeps the workspace model outside the short list visible as the current model' do
          account.update!(captain_models: { 'assistant' => 'vendor/model-7' })
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.4", "openai/gpt-5.4-mini"]')

          fetch_preferences

          assistant = json_response.dig(:features, :assistant)
          expect(assistant[:selected]).to eq('vendor/model-7')
          expect(assistant[:models]).to include(include(id: 'vendor/model-7', current_only: true))
          expect(assistant[:models].reject { |model| model[:current_only] }.pluck(:id)).to contain_exactly(
            'openai/gpt-5.4', 'openai/gpt-5.4-mini'
          )
        end
      end

      it 'ignores an account OpenRouter key when the platform has not enabled workspace keys' do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
        create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:provider_credentials, :openrouter)).to include(
          byok_allowed: false,
          source: 'global'
        )
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'reports OpenRouter credential status without exposing the account key' do
        account.enable_features!('captain_openrouter_byok')
        create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:provider_credentials, :openrouter)).to include(
          account_configured: true,
          provider_configured: true,
          source: 'account'
        )
        expect(json_response.dig(:provider_credentials, :openrouter, :health)).to include(
          status: 'workspace_key_configured',
          source: 'account'
        )
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'reports cached global OpenRouter key health without exposing key details' do
        allow(Llm::Config).to receive(:installation_provider_available?).and_call_original
        allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
        allow(Llm::Config).to receive(:provider_available?).and_call_original
        allow(Llm::Config).to receive(:provider_available?).with('openrouter', account: account).and_return(true)
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(
          {
            status: 'valid',
            checked_at: '2026-05-31T10:00:00Z',
            key: { label: 'sk-or-v1-secret', key_type: 'management' },
            credits: { status: 'available', remaining_credits: 10.5 }
          }
        )

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:provider_credentials, :openrouter, :health)).to include(
          status: 'valid',
          source: 'global',
          checked_at: '2026-05-31T10:00:00Z',
          credits_status: 'available'
        )
        expect(response.body).not_to include('sk-or-v1-secret')
        expect(response.body).not_to include('remaining_credits')
      end

      it 'reports visible provider credential statuses only' do
        create(:integrations_hook, account: account, app_id: 'openai', settings: { api_key: 'account-openai-key' })

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:provider_credentials].keys).to contain_exactly(:openrouter)
        expect(json_response[:provider_credentials]).not_to have_key(:openai)
        expect(response.body).not_to include('account-openai-key')
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/captain/preferences' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            params: { captain_models: { editor: 'gpt-4.1-mini' } },
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns forbidden' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: agent.create_new_auth_token,
            params: { captain_models: { editor: 'gpt-4.1-mini' } },
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the captain_models an account may still choose' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { editor: 'gpt-4.1-mini' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        expect(account.reload.captain_models).to include('editor' => 'gpt-4.1-mini')
      end

      it 'rejects installation-managed model overrides' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_models: {
                editor: 'gpt-4.1-mini',
                audio_transcription: 'whisper-1',
                image_recognition: 'gpt-5.4-mini',
                help_center_search: 'text-embedding-3-small',
                moderation: 'openai/gpt-oss-safeguard-20b',
                label_suggestion: 'gpt-4.1-mini'
              }
            },
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_response[:error]).to eq('installation_managed_models')
        expect(json_response[:fields]).to contain_exactly(
          'audio_transcription', 'image_recognition', 'help_center_search', 'moderation', 'label_suggestion'
        )
        expect(account.reload.captain_models).to be_blank
      end

      it 'removes stale installation-managed overrides on the next preferences update' do
        account.update!(captain_models: { 'audio_transcription' => 'whisper-1', 'editor' => 'gpt-4.1' })

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_features: { editor: true } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_models).to eq('editor' => 'gpt-4.1')
      end

      it 'rejects an assistant model the platform did not put on its short list' do
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.6-luna"]')

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { assistant: 'openai/gpt-6-luna' } },
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_response).to eq(error: 'model_not_allowed', fields: ['assistant'])
        expect(account.reload.captain_models).to be_blank
      end

      it 'accepts an assistant model from the short list' do
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.6-luna"]')

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { assistant: 'openai/gpt-5.6-luna' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_models).to include('assistant' => 'openai/gpt-5.6-luna')
      end

      it 'lets an account keep sending the assistant model it already uses even when it is off the short list' do
        account.update!(captain_models: { 'assistant' => 'openai/gpt-6-luna' })
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.6-luna"]')

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { assistant: 'openai/gpt-6-luna' } },
            as: :json

        expect(response).to have_http_status(:success)
      end

      it 'does not restrict the editor and copilot models, only what the client is shown' do
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.6-luna"]')

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { editor: 'gpt-4.1-mini', copilot: 'gpt-5.1' } },
            as: :json

        expect(response).to have_http_status(:success)
      end

      it 'keeps an assistant model chosen before the short list existed when other models change' do
        account.update!(captain_models: { 'assistant' => 'openai/gpt-6-luna' })
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-5.6-luna"]')

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { editor: 'gpt-4.1-mini' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_models).to include('assistant' => 'openai/gpt-6-luna', 'editor' => 'gpt-4.1-mini')
      end

      it 'updates captain_features' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_features: { editor: true } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        expect(account.reload.captain_features['editor']).to be true
      end

      it 'saves the text improvement switch under its own key' do
        account.update!(captain_features: { 'editor' => false, 'label_suggestion' => true })
        # One session: a second create_new_auth_token replaces the first one.
        auth_headers = admin.create_new_auth_token

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: auth_headers,
            params: { captain_features: { text_improvement: false } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:features, :editor, :enabled)).to be(false)
        expect(account.reload.captain_features).to include(
          'text_improvement' => false, 'editor' => false, 'label_suggestion' => true
        )
        expect(account.captain_editor_enabled?).to be false

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: auth_headers,
            params: { captain_features: { text_improvement: true } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('features', 'editor', 'enabled')).to be(true)
        expect(account.reload.captain_editor_enabled?).to be true
      end

      it 'updates captain_runtime' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_runtime: {
                privacy_profile: 'sensitive',
                assistant_thinking_effort: 'high',
                assistant_moderation: true,
                openrouter_allow_model_fallbacks: false,
                moderation_failure_mode: 'fail_closed',
                assistant_prompt_injection_guardrail: 'flag',
                assistant_sensitive_info_guardrail: false,
                copilot_prompt_injection_guardrail: 'disabled',
                copilot_sensitive_info_guardrail: true,
                audio_transcription_prompt: 'Recognize customer speech in Russian and Kazakh.',
                knowledge_chunk_size: '32000',
                safety_blocklist: ['never disclose api keys'],
                assistant_safety_blocklist: ['do not discuss payroll'],
                openrouter_routing_strategy: 'auto-exacto',
                openrouter_provider_order: ['OpenAI', '', 'Anthropic'],
                agent_high_risk_tools: 'disabled',
                agent_high_risk_tool_ids: ['create_deal'],
                release_gate: {
                  enabled: 'true',
                  min_request_count: '20',
                  max_error_rate: '0.05'
                }
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:runtime]).to include(
          privacy_profile: 'sensitive',
          assistant_thinking_effort: 'high',
          assistant_moderation: true,
          openrouter_allow_model_fallbacks: false,
          moderation_failure_mode: 'fail_closed',
          assistant_prompt_injection_guardrail: 'flag',
          assistant_sensitive_info_guardrail: 'disabled',
          copilot_prompt_injection_guardrail: 'disabled',
          copilot_sensitive_info_guardrail: 'block',
          audio_transcription_prompt: 'Recognize customer speech in Russian and Kazakh.',
          knowledge_chunk_size: 32_000,
          safety_blocklist: ['never disclose api keys'],
          assistant_safety_blocklist: ['do not discuss payroll'],
          openrouter_routing_strategy: 'auto_exacto',
          openrouter_provider_order: %w[OpenAI Anthropic],
          agent_high_risk_tools: 'disabled',
          agent_high_risk_tool_ids: ['create_deal'],
          release_gate: {
            enabled: true,
            min_request_count: 20,
            max_error_rate: 0.05
          }
        )
        expect(account.reload.captain_runtime).to include(
          'privacy_profile' => 'sensitive',
          'assistant_thinking_effort' => 'high',
          'assistant_moderation' => true,
          'openrouter_allow_model_fallbacks' => false,
          'moderation_failure_mode' => 'fail_closed',
          'assistant_prompt_injection_guardrail' => 'flag',
          'assistant_sensitive_info_guardrail' => 'disabled',
          'copilot_prompt_injection_guardrail' => 'disabled',
          'copilot_sensitive_info_guardrail' => 'block',
          'audio_transcription_prompt' => 'Recognize customer speech in Russian and Kazakh.',
          'knowledge_chunk_size' => 32_000,
          'safety_blocklist' => ['never disclose api keys'],
          'assistant_safety_blocklist' => ['do not discuss payroll'],
          'openrouter_routing_strategy' => 'auto_exacto',
          'openrouter_provider_order' => %w[OpenAI Anthropic],
          'agent_high_risk_tools' => 'disabled',
          'agent_high_risk_tool_ids' => ['create_deal'],
          'release_gate' => {
            'enabled' => true,
            'min_request_count' => 20,
            'max_error_rate' => 0.05
          }
        )
      end

      it 'updates aliased OpenRouter routing runtime preferences' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_runtime: {
                routing_strategy: 'exacto',
                provider_order: ['OpenAI', ' ', 'Fireworks']
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_runtime).to include(
          'routing_strategy' => 'exacto',
          'provider_order' => %w[OpenAI Fireworks]
        )
      end

      it 'leaves the platform-managed embedding model alone when the knowledge chunk size changes' do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
        allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
          'openai/text-embedding-3-small' => {
            'provider' => 'openrouter',
            'display_name' => 'Text Embedding 3 Small',
            'type' => 'embedding',
            'capabilities' => %w[embedding text_input],
            'embedding_dimensions' => 1536,
            'context_length' => 8192
          },
          'openai/text-embedding-long-context' => {
            'provider' => 'openrouter',
            'display_name' => 'Long Context Embedding',
            'type' => 'embedding',
            'capabilities' => %w[embedding text_input],
            'embedding_dimensions' => 1536,
            'context_length' => 10_000
          }
        )
        upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'openai/text-embedding-long-context')
        account.update!(
          captain_models: { 'help_center_search' => 'openai/text-embedding-3-small' },
          captain_runtime: { 'knowledge_chunk_size' => 20_000 }
        )

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_runtime: { knowledge_chunk_size: '40000' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:runtime, :knowledge_chunk_size)).to eq(40_000)
        expect(json_response.dig(:features, :help_center_search, :selected)).to eq('openai/text-embedding-long-context')
        expect(json_response.dig(:features, :help_center_search, :managed)).to be(true)

        account.reload
        expect(account.captain_runtime['knowledge_chunk_size']).to eq(40_000)
        expect(account.captain_models).not_to have_key('help_center_search')
      end

      it 'merges with existing captain_models' do
        account.update!(captain_models: { 'editor' => 'gpt-4.1-mini', 'assistant' => 'gpt-5.1' })

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_models: { editor: 'gpt-4.1' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        models = account.reload.captain_models
        expect(models['editor']).to eq('gpt-4.1')
        expect(models['assistant']).to eq('gpt-5.1') # Preserved
      end

      it 'merges with existing captain_features' do
        account.update!(captain_features: { 'editor' => true, 'assistant' => false })

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_features: { editor: false } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        features = account.reload.captain_features
        expect(features['editor']).to be false
        expect(features['assistant']).to be false # Preserved
      end

      it 'merges with existing captain_runtime' do
        account.update!(captain_runtime: {
                          'assistant_thinking_effort' => 'medium',
                          'assistant_moderation' => false
                        })

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_runtime: { assistant_moderation: true } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_runtime).to include(
          'assistant_thinking_effort' => 'medium',
          'assistant_moderation' => true
        )
      end

      it 'stores normalized web access runtime settings and returns Firecrawl metadata' do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_runtime: {
                web_search_enabled: true,
                web_scrape_enabled: true,
                web_document_parse_enabled: true,
                web_search_max_results: 99,
                web_scrape_max_chars: 99_999,
                web_document_parse_max_chars: 99_999,
                web_allowed_domains: ['https://Example.com/docs'],
                web_blocked_domains: ['Bad.Example.com/path']
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_runtime).to include(
          'web_search_enabled' => true,
          'web_scrape_enabled' => true,
          'web_document_parse_enabled' => true,
          'web_search_max_results' => Llm::RuntimePolicy::WEB_SEARCH_MAX_LIMIT,
          'web_scrape_max_chars' => Llm::RuntimePolicy::WEB_SCRAPE_MAX_CHARS,
          'web_document_parse_max_chars' => Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_MAX_CHARS,
          'web_allowed_domains' => ['example.com'],
          'web_blocked_domains' => ['bad.example.com']
        )
        expect(json_response.dig(:runtime_metadata, :web_access)).to include(
          provider: 'firecrawl',
          configured: true,
          search_max_results: Llm::RuntimePolicy::WEB_SEARCH_MAX_LIMIT,
          scrape_max_chars: Llm::RuntimePolicy::WEB_SCRAPE_MAX_CHARS,
          document_parse_max_chars: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_MAX_CHARS,
          document_parse_max_file_bytes: Llm::RuntimePolicy.web_document_parse_max_file_bytes,
          document_parse_provider_max_file_bytes: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_PROVIDER_MAX_FILE_BYTES
        )
      end

      it 'updates both models and features in single request' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_models: { editor: 'gpt-4.1-mini' },
              captain_features: { editor: true }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        account.reload
        expect(account.captain_models['editor']).to eq('gpt-4.1-mini')
        expect(account.captain_features['editor']).to be true
      end

      it 'updates captain_observability settings' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_observability: {
                default_lookback_days: 14,
                retention_days: 180,
                saved_views: [
                  {
                    id: 'saved-1',
                    name: 'Assistant errors',
                    tab: 'events',
                    filters: { feature: 'assistant', flag: 'error', trace_id: 'trace-1' }
                  }
                ],
                alert_channels: {
                  enabled: true,
                  minimum_severity: 'critical',
                  email_recipients: ['Ops@Example.com'],
                  webhook_url: 'https://example.com/alerts',
                  notify_on: ['operational_release_gate']
                }
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:observability]).to include(
          default_lookback_days: 14,
          retention_days: 180
        )
        expect(json_response.dig(:observability, :saved_views)).to include(
          include(
            id: 'saved-1',
            name: 'Assistant errors',
            tab: 'events',
            filters: include(feature: 'assistant', flag: 'error', trace_id: 'trace-1')
          )
        )
        expect(json_response.dig(:observability, :alert_channels)).to include(
          enabled: true,
          minimum_severity: 'critical',
          email_recipients: ['ops@example.com'],
          webhook_url: 'https://example.com/alerts',
          notify_on: ['operational_release_gate']
        )
        expect(account.reload.captain_observability).to include(
          'default_lookback_days' => 14,
          'retention_days' => 180
        )
        expect(account.reload.captain_observability.dig('saved_views', 0, 'filters')).to include(
          'trace_id' => 'trace-1'
        )
      end

      it 'ignores removed budget settings without changing stored policy rows' do
        policy = create(:llm_budget_policy, account: account, daily_budget: 1.0, hard_stop: true)

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_budget: { daily_budget: 2.5, hard_stop: false } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(policy.reload).to have_attributes(daily_budget: 1.0, hard_stop: true)
      end

      it 'blocks account provider keys while the platform has not enabled workspace keys' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { openrouter_api_key: 'account-openrouter-key' },
            as: :json

        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq(error: 'provider_byok_disabled', providers: ['openrouter'])
        expect(account.hooks.find_by(app_id: 'openrouter')).to be_nil
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'blocks provider credentials sent in the grouped form as well' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openrouter: { api_key: 'account-openrouter-key' } } },
            as: :json

        expect(response).to have_http_status(:forbidden)
        expect(json_response[:error]).to eq('provider_byok_disabled')
        expect(account.hooks.find_by(app_id: 'openrouter')).to be_nil
      end

      it 'does not apply the other changes of a request that carries a blocked provider key' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { captain_runtime: { web_search_enabled: true }, openrouter_api_key: 'account-openrouter-key' },
            as: :json

        expect(response).to have_http_status(:forbidden)
        expect(account.reload.captain_runtime.to_h).not_to include('web_search_enabled' => true)
      end

      it 'saves the on/off toggles of the recognition and web features' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_features: { audio_transcription: true, help_center_search: true, label_suggestion: true },
              captain_runtime: {
                assistant_moderation: true,
                copilot_moderation: true,
                web_search_enabled: true,
                web_scrape_enabled: true,
                web_document_parse_enabled: true
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.reload.captain_features).to include(
          'audio_transcription' => true, 'help_center_search' => true, 'label_suggestion' => true
        )
        expect(account.captain_runtime).to include(
          'assistant_moderation' => true,
          'copilot_moderation' => true,
          'web_search_enabled' => true,
          'web_scrape_enabled' => true,
          'web_document_parse_enabled' => true
        )
      end

      it 'stores an OpenRouter account key via Integrations::Hook without returning the secret' do
        account.enable_features!('captain_openrouter_byok')
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { openrouter_api_key: 'account-openrouter-key' },
            as: :json

        expect(response).to have_http_status(:success)
        hook = account.hooks.find_by!(app_id: 'openrouter')
        expect(hook.access_token).to eq('account-openrouter-key')
        expect(json_response.dig(:provider_credentials, :openrouter)).to include(
          account_configured: true,
          source: 'account'
        )
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'removes an OpenRouter account key without returning the secret' do
        create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { remove_openrouter_api_key: true },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.hooks.find_by(app_id: 'openrouter')).to be_nil
        expect(json_response.dig(:provider_credentials, :openrouter, :account_configured)).to be false
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'stores visible provider account keys via provider credentials' do
        account.enable_features!('captain_openrouter_byok')
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openrouter: { api_key: 'account-openrouter-key' } } },
            as: :json

        expect(response).to have_http_status(:success)
        hook = account.hooks.find_by!(app_id: 'openrouter')
        expect(hook.access_token).to eq('account-openrouter-key')
        expect(hook.settings).not_to include('api_key')
        expect(json_response.dig(:provider_credentials, :openrouter)).to include(
          account_configured: true,
          source: 'account'
        )
        expect(response.body).not_to include('account-openrouter-key')
      end

      it 'ignores malformed provider credential payload values' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openrouter: 'not-a-credential-hash' } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.hooks.find_by(app_id: 'openrouter')).to be_nil
        expect(json_response.dig(:provider_credentials, :openrouter, :account_configured)).to be false
      end

      it 'ignores hidden direct provider account keys in normal Captain settings' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openai: { api_key: 'account-openai-key' } } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.hooks.find_by(app_id: 'openai')).to be_nil
        expect(json_response[:provider_credentials]).not_to have_key(:openai)
        expect(response.body).not_to include('account-openai-key')
      end

      it 'removes visible provider account keys via provider credentials' do
        create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key',
                                   settings: { api_key: 'account-openrouter-key' })
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openrouter: { remove: true } } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.hooks.find_by(app_id: 'openrouter')).to be_nil
        expect(json_response.dig(:provider_credentials, :openrouter, :account_configured)).to be false
      end

      it 'does not remove hidden direct provider account keys from normal Captain settings' do
        hook = create(:integrations_hook, account: account, app_id: 'openai', access_token: 'account-openai-key',
                                          settings: { api_key: 'account-openai-key' })
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: { provider_credentials: { openai: { remove: true } } },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account.hooks.find_by(app_id: 'openai')).to eq(hook)
        expect(json_response[:provider_credentials]).not_to have_key(:openai)
      end
    end
  end
end
