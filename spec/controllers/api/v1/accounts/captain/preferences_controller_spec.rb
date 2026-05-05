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
      it 'returns captain config' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        expect(json_response).to have_key(:runtime_metadata)
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

      it 'includes the latest selectable models in settings payload' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:models]).to include(
          :'gpt-5.4',
          :'gpt-5.4-mini',
          :'claude-sonnet-4-6',
          :'claude-opus-4-6',
          :'gemini-2.5-pro',
          :'gemini-2.5-flash'
        )
      end

      it 'includes runtime metadata for resolved providers and feature models' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:runtime_metadata)
        expect(json_response.dig(:runtime_metadata, :providers, :openai)).to include(:configured, :display_name)
        expect(json_response.dig(:runtime_metadata, :providers, :openrouter)).to include(:configured, :display_name, :models_api)
        expect(json_response.dig(:runtime_metadata, :registry, :openrouter)).to include(:total_models, :using_fallback)
        expect(json_response.dig(:runtime_metadata, :features, :assistant)).to include(:selected_model, :provider)
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
      it 'updates captain_models' do
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
        expect(account.reload.captain_models['editor']).to eq('gpt-4.1-mini')
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

      it 'updates captain_runtime' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_runtime: {
                assistant_thinking_effort: 'high',
                assistant_moderation: true,
                moderation_failure_mode: 'fail_closed',
                audio_transcription_prompt: 'Recognize customer speech in Russian and Kazakh.',
                safety_blocklist: ['never disclose api keys'],
                assistant_safety_blocklist: ['do not discuss payroll'],
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
          assistant_thinking_effort: 'high',
          assistant_moderation: true,
          moderation_failure_mode: 'fail_closed',
          audio_transcription_prompt: 'Recognize customer speech in Russian and Kazakh.',
          safety_blocklist: ['never disclose api keys'],
          assistant_safety_blocklist: ['do not discuss payroll'],
          agent_high_risk_tools: 'disabled',
          agent_high_risk_tool_ids: ['create_deal'],
          release_gate: {
            enabled: true,
            min_request_count: 20,
            max_error_rate: 0.05
          }
        )
        expect(account.reload.captain_runtime).to include(
          'assistant_thinking_effort' => 'high',
          'assistant_moderation' => true,
          'moderation_failure_mode' => 'fail_closed',
          'audio_transcription_prompt' => 'Recognize customer speech in Russian and Kazakh.',
          'safety_blocklist' => ['never disclose api keys'],
          'assistant_safety_blocklist' => ['do not discuss payroll'],
          'agent_high_risk_tools' => 'disabled',
          'agent_high_risk_tool_ids' => ['create_deal'],
          'release_gate' => {
            'enabled' => true,
            'min_request_count' => 20,
            'max_error_rate' => 0.05
          }
        )
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
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/preferences/refresh_openrouter_models' do
    after do
      Rails.cache.delete(Llm::OpenRouterModelCatalog::CACHE_KEY)
      Rails.cache.delete(Llm::OpenRouterModelCatalog::LAST_REFRESH_AT_CACHE_KEY)
      Rails.cache.delete(Llm::OpenRouterModelCatalog::LAST_REFRESH_ERROR_CACHE_KEY)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'refreshes OpenRouter models and returns updated settings payload' do
        expect(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_return(total_models: 1)

        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:runtime_metadata)
      end

      it 'fetches OpenRouter API models through the refresh endpoint without real network calls' do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
        stub_request(:get, 'https://openrouter.ai/api/v1/models')
          .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
          .to_return(
            status: 200,
            body: {
              data: [
                {
                  id: 'openai/gpt-4o',
                  name: 'GPT-4o via OpenRouter',
                  architecture: { input_modalities: ['text'], output_modalities: ['text'] },
                  context_length: 128_000,
                  top_provider: { max_completion_tokens: 16_384 },
                  supported_parameters: %w[tools response_format]
                }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        openrouter_model = json_response.dig(:features, :assistant, :models).find { |model| model[:id] == 'openai/gpt-4o' }
        expect(openrouter_model).to include(
          provider: 'openrouter',
          provider_display_name: 'OpenRouter',
          source: 'openrouter_api',
          context_length: 128_000,
          max_output_tokens: 16_384
        )
      end

      it 'returns validation error when OpenRouter API key is missing' do
        allow(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_raise(
          Llm::OpenRouterModelCatalog::MissingApiKeyError, 'OpenRouter API key is not configured.'
        )

        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:error]).to eq('OpenRouter API key is not configured.')
      end

      it 'returns a sanitized gateway error when refresh fails unexpectedly' do
        allow(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_raise(
          StandardError, 'upstream leaked Bearer sk-or-v1-secret and api_key=SECRET_VALUE'
        )

        post "/api/v1/accounts/#{account.id}/captain/preferences/refresh_openrouter_models",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(json_response[:error]).to eq('OpenRouter models refresh failed.')
        expect(response.body).not_to include('sk-or-v1-secret')
        expect(response.body).not_to include('[REDACTED]')
      end
    end
  end
end
