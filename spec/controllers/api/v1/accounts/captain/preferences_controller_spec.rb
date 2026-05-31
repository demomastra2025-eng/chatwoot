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

      it 'includes OpenRouter models only in the normal Captain settings payload' do
        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:providers].keys).to contain_exactly(:openrouter)
        expect(json_response[:models].keys).to include(:'openai/gpt-5.4', :'openai/gpt-5.4-mini')
        expect(json_response[:models].values).to all(include(provider: 'openrouter'))
        expect(json_response[:models].keys).not_to include(:'gpt-5.4', :'claude-sonnet-4-6', :'gemini-2.5-pro')
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

      it 'includes account OpenRouter usage, budget status, and runtime health summary' do
        create(:llm_budget_policy, account: account, daily_budget: 1.0, monthly_budget: 10.0, hard_stop: true)
        create(:llm_usage_event, account: account, feature: 'assistant', actual_model: 'openai/gpt-5.4-mini',
                                 estimated_cost: 0.25, total_tokens: 120, occurred_at: Time.current)
        create(:llm_usage_event, account: account, feature: 'help_center_search', actual_model: 'openai/text-embedding-3-small',
                                 estimated_cost: 0.05, total_tokens: 30, occurred_at: Time.current)
        create(:llm_usage_event, account: account, status: 'error', error_code: 'provider_error',
                                 actual_model: 'openai/gpt-5.4-mini', estimated_cost: 0,
                                 total_tokens: 0, occurred_at: Time.current)
        create(:llm_event, account: account, provider: 'openrouter', error: true, retry_count: 1, schema_invalid: true)

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:usage]).to include(currency: 'USD')
        expect(json_response.dig(:usage, :windows, :today)).to include(
          request_count: 3,
          estimated_cost: 0.3,
          total_tokens: 150
        )
        expect(json_response.dig(:usage, :budgets, :account_policy)).to include(
          daily_budget: 1.0,
          monthly_budget: 10.0,
          hard_stop: true
        )
        expect(json_response.dig(:usage, :budgets, :account_policy, :daily)).to include(
          spend: 0.3,
          limit: 1.0,
          remaining: 0.7,
          status: 'ok'
        )
        expect(json_response.dig(:usage, :top_models)).to include(
          include(actual_model: 'openai/gpt-5.4-mini', request_count: 2)
        )
        expect(json_response.dig(:usage, :recent_errors)).to include(
          include(error_code: 'provider_error', model: 'openai/gpt-5.4-mini')
        )
        expect(json_response.dig(:usage, :runtime_health)).to include(
          total_events: 1,
          error_count: 1,
          retry_count: 1,
          schema_invalid_count: 1
        )
      end

      it 'includes backend diagnostics for searchable OpenRouter models hidden from a feature' do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
        allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
          'openai/gpt-5.4' => {
            'provider' => 'openrouter',
            'display_name' => 'GPT 5.4',
            'type' => 'chat',
            'capabilities' => %w[text_input text_output structured_output tool_calling]
          },
          'openai/gpt-text-only' => {
            'provider' => 'openrouter',
            'display_name' => 'GPT Text Only',
            'type' => 'chat',
            'capabilities' => %w[text_input text_output structured_output]
          }
        )

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:features, :assistant, :models)).to include(include(id: 'openai/gpt-5.4'))
        expect(json_response.dig(:features, :assistant, :models)).not_to include(include(id: 'openai/gpt-text-only'))
        expect(json_response.dig(:features, :assistant, :diagnostic_models)).to include(
          include(
            id: 'openai/gpt-text-only',
            diagnostic_only: true,
            diagnostics: include(
              allowed: false,
              reasons: include(include(code: 'tool_calling_unsupported'))
            )
          )
        )
      end

      it 'reports OpenRouter credential status without exposing the account key' do
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
        create(:integrations_hook, account: account, app_id: 'anthropic', access_token: 'account-anthropic-key', settings: {})

        get "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:provider_credentials].keys).to contain_exactly(:openrouter)
        expect(json_response[:provider_credentials]).not_to have_key(:anthropic)
        expect(response.body).not_to include('account-anthropic-key')
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
      it 'updates captain_models for chat and specialized AI surfaces' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_models: {
                editor: 'gpt-4.1-mini',
                audio_transcription: 'whisper-1',
                image_recognition: 'gpt-5.4-mini',
                help_center_search: 'text-embedding-3-small',
                moderation: 'openai/gpt-oss-safeguard-20b'
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to have_key(:providers)
        expect(json_response).to have_key(:models)
        expect(json_response).to have_key(:features)
        expect(json_response).to have_key(:runtime)
        expect(json_response).to have_key(:observability)
        expect(account.reload.captain_models).to include(
          'editor' => 'gpt-4.1-mini',
          'audio_transcription' => 'whisper-1',
          'image_recognition' => 'gpt-5.4-mini',
          'help_center_search' => 'text-embedding-3-small',
          'moderation' => 'openai/gpt-oss-safeguard-20b'
        )
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
                privacy_profile: 'sensitive',
                assistant_thinking_effort: 'high',
                assistant_moderation: true,
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

      it 'replaces an incompatible saved embedding model when the knowledge chunk size changes' do
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
        account.update!(
          captain_models: { 'help_center_search' => 'openai/text-embedding-3-small' },
          captain_runtime: { 'knowledge_chunk_size' => 20_000 }
        )

        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_models: { audio_transcription: nil },
              captain_runtime: { knowledge_chunk_size: '40000' }
            },
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response.dig(:runtime, :knowledge_chunk_size)).to eq(40_000)
        expect(json_response.dig(:features, :help_center_search, :selected)).to eq('openai/text-embedding-long-context')

        account.reload
        expect(account.captain_runtime['knowledge_chunk_size']).to eq(40_000)
        expect(account.captain_models['help_center_search']).to eq('openai/text-embedding-long-context')
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

      it 'updates the account OpenRouter budget policy' do
        put "/api/v1/accounts/#{account.id}/captain/preferences",
            headers: admin.create_new_auth_token,
            params: {
              captain_budget: {
                active: true,
                hard_stop: true,
                daily_budget: '2.50',
                monthly_budget: '50',
                warning_threshold: '0.75'
              }
            },
            as: :json

        expect(response).to have_http_status(:success)
        policy = LlmBudgetPolicy.find_by!(account: account, scope_type: 'account', feature: nil)
        expect(policy).to have_attributes(
          active: true,
          hard_stop: true,
          daily_budget: 2.5,
          monthly_budget: 50.0,
          warning_threshold: 0.75
        )
        expect(json_response.dig(:usage, :budgets, :account_policy)).to include(
          active: true,
          hard_stop: true,
          daily_budget: 2.5,
          monthly_budget: 50.0,
          warning_threshold: 0.75
        )
      end

      it 'stores an OpenRouter account key via Integrations::Hook without returning the secret' do
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
