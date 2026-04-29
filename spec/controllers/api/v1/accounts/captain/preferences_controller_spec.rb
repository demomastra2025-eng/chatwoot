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
end
