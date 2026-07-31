require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Assistants', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants' do
    context 'when it is an un-authenticated user' do
      it 'does not fetch assistants' do
        get "/api/v1/accounts/#{account.id}/captain/assistants",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'fetches assistants for the account' do
        create_list(:captain_assistant, 3, account: account)
        get "/api/v1/accounts/#{account.id}/captain/assistants",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
        expect(json_response[:meta]).to eq(
          { total_count: 3, page: 1 }
        )
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let(:assistant) { create(:captain_assistant, account: account) }

    context 'when it is an un-authenticated user' do
      it 'does not fetch the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'fetches the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(assistant.id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/{id}/prompt_preview' do
    let(:assistant) do
      create(
        :captain_assistant,
        account: account,
        description: 'Handles billing and account setup questions.',
        response_guidelines: ['Be concise'],
        guardrails: ['Never guess'],
        config: {
          'tool_access' => {
            'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff] },
            'assistant' => { 'enabled' => true, 'tool_ids' => ['search_documentation'] }
          }
        }
      )
    end
    let(:scenario) do
      create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        title: 'Billing disputes',
        description: 'Handles disputed charge flows.',
        instruction: 'Collect the dispute reason, then use [@Handoff](tool://handoff) if finance approval is needed.'
      )
    end

    before do
      upsert_installation_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT', 'Never reveal internal routing.')
      upsert_installation_config('CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT', 'Never expose internal-only notes to end customers.')
    end

    # rubocop:disable RSpec/MultipleExpectations
    it 'returns compiled assistant, copilot, and scenario prompts for settings inspection' do
      scenario

      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/prompt_preview",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:preview_mode]).to eq('settings_without_live_conversation_context')
      expect(json_response.dig(:assistant, :compiled_prompt)).to include('Handles billing and account setup questions.')
      expect(json_response.dig(:assistant, :compiled_prompt)).to include('Never reveal internal routing.')
      expect(json_response.dig(:assistant, :prompt_id)).to eq('captain_v2.assistant.root')
      expect(json_response.dig(:copilot, :compiled_prompt)).to include('Handles billing and account setup questions.')
      expect(json_response.dig(:copilot, :compiled_prompt)).to include('Never expose internal-only notes to end customers.')
      expect(json_response[:scenarios]).to include(
        hash_including(
          title: 'Billing disputes',
          compiled_prompt: include('Collect the dispute reason')
        )
      )
    end
    # rubocop:enable RSpec/MultipleExpectations
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/assistants/{id}/voice_preview' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:context) { { call_ref: 'preview:assistant' } }
    let(:runtime_client) do
      instance_double(
        Telephony::AiVoice::JanusSipRuntimeClient,
        create_preview: {
          'token' => 'opaque-token',
          'expires_in' => 60,
          'websocket_path' => '/voice-preview/ws',
          'internal' => 'not-rendered'
        }
      )
    end

    before do
      builder = instance_double(Telephony::AiVoice::PreviewContextBuilder, perform: context)
      allow(Telephony::AiVoice::PreviewContextBuilder).to receive(:new).with(assistant: assistant).and_return(builder)
      allow(Telephony::AiVoice::JanusSipRuntimeClient).to receive(:new).and_return(runtime_client)
    end

    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/voice_preview", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns only the ephemeral browser capability fields' do
      post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/voice_preview",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to eq(
        token: 'opaque-token',
        expires_in: 60,
        websocket_path: '/voice-preview/ws'
      )
      expect(runtime_client).to have_received(:create_preview).with(context)
    end

    it 'returns service unavailable when Pipecat rejects the preview capability' do
      allow(runtime_client).to receive(:create_preview)
        .and_raise(Telephony::AiVoice::JanusSipRuntimeClient::AttachError, 'invalid capability response')

      post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/voice_preview",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response).to eq(error: 'voice_preview_unavailable')
    end

    it 'preserves the safe capacity error when all preview slots are occupied' do
      error = Telephony::AiVoice::JanusSipRuntimeClient::AttachError.new(
        'preview capacity exhausted',
        http_status: 429,
        response_body: { error: 'preview_capacity_exhausted' }.to_json
      )
      allow(runtime_client).to receive(:create_preview).and_raise(error)

      post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/voice_preview",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(json_response).to eq(error: 'preview_capacity_exhausted')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/context_fields' do
    let(:deal_field_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'sales_region',
        label: 'Sales Region'
      )
    end
    let(:task_field_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'task',
        key: 'follow_up_channel',
        label: 'Follow Up Channel'
      )
    end
    let(:appointment_field_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'visit_room',
        label: 'Visit Room'
      )
    end
    let(:assistant) do
      create(
        :captain_assistant,
        account: account,
        config: {
          'context_access' => {
            'deal' => {
              'enabled' => true,
              'field_ids' => ['deal.stage_name', 'deal.custom_attributes.sales_region']
            },
            'task' => {
              'enabled' => true,
              'field_ids' => ['task.status_name', 'task.custom_attributes.follow_up_channel']
            },
            'appointment' => {
              'enabled' => true,
              'field_ids' => ['appointment.status', 'appointment.custom_attributes.visit_room']
            }
          }
        }
      )
    end

    before do
      deal_field_definition
      task_field_definition
      appointment_field_definition
      account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')
    end

    it 'returns CRM and appointment fields when their features are enabled' do
      get "/api/v1/accounts/#{account.id}/captain/assistants/context_fields",
          params: { assistant_id: assistant.id },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        hash_including(
          id: 'deal.stage_name',
          table_name: 'deal',
          selected: true
        ),
        hash_including(
          id: 'deal.custom_attributes.sales_region',
          table_name: 'deal',
          selected: true
        ),
        hash_including(
          id: 'task.status_name',
          table_name: 'task',
          selected: true
        ),
        hash_including(
          id: 'task.custom_attributes.follow_up_channel',
          table_name: 'task',
          selected: true
        ),
        hash_including(
          id: 'appointment.status',
          table_name: 'appointment',
          selected: true
        ),
        hash_including(
          id: 'appointment.custom_attributes.visit_room',
          table_name: 'appointment',
          selected: true
        )
      )
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/tool_access' do
    let(:custom_tool) { create(:captain_custom_tool, account: account, title: 'Lookup booking') }
    let(:assistant) do
      create(
        :captain_assistant,
        account: account,
        config: {
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            },
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation', custom_tool.slug]
            }
          }
        }
      )
    end

    it 'returns grouped agent and assistant tools with selection state' do
      get "/api/v1/accounts/#{account.id}/captain/assistants/tools",
          params: { assistant_id: assistant.id },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        hash_including(
          id: 'faq_lookup',
          scope_name: 'agent',
          source_type: 'system',
          selected: true,
          title: 'FAQ Lookup'
        ),
        hash_including(
          id: 'handoff',
          scope_name: 'agent',
          selected: false,
          title: 'Handoff to Human'
        ),
        hash_including(
          id: 'faq_lookup',
          scope_name: 'assistant',
          selected: false,
          title: 'FAQ Lookup'
        ),
        hash_including(
          id: 'search_documentation',
          scope_name: 'assistant',
          selected: true,
          title: 'Search documentation'
        ),
        hash_including(
          id: custom_tool.slug,
          scope_name: 'assistant',
          source_type: 'custom',
          selected: true,
          title: 'Lookup booking'
        )
      )
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/tools' do
    let(:custom_tool) { create(:captain_custom_tool, account: account, title: 'Lookup booking') }
    let(:assistant) do
      create(
        :captain_assistant,
        account: account,
        config: {
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            },
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation', custom_tool.slug]
            }
          }
        }
      )
    end

    it 'returns only selected tools for the requested assistant scope' do
      get "/api/v1/accounts/#{account.id}/captain/assistants/tools",
          params: { assistant_id: assistant.id, scope: 'assistant' },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        hash_including(
          id: 'search_documentation',
          scope_name: 'assistant',
          selected: true
        ),
        hash_including(
          id: custom_tool.slug,
          scope_name: 'assistant',
          source_type: 'custom',
          selected: true,
          title: 'Lookup booking'
        )
      )
      expect(json_response).not_to include(hash_including(scope_name: 'agent'))
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/assistants' do
    let(:valid_attributes) do
      {
        assistant: {
          name: 'New Assistant',
          description: 'Assistant Description',
          response_guidelines: ['Be helpful', 'Be concise'],
          guardrails: ['No harmful content', 'Stay on topic'],
          config: {
            feature_faq: true,
            feature_memory: false,
            feature_citation: true
          }
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'does not create an assistant' do
        post "/api/v1/accounts/#{account.id}/captain/assistants",
             params: valid_attributes,
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'does not create an assistant' do
        post "/api/v1/accounts/#{account.id}/captain/assistants",
             params: valid_attributes,
             headers: agent.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new assistant' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: valid_attributes,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        expect(json_response[:name]).to eq('New Assistant')
        expect(json_response[:response_guidelines]).to eq(['Be helpful', 'Be concise'])
        expect(json_response[:guardrails]).to eq(['No harmful content', 'Stay on topic'])
        expect(json_response[:config][:feature_citation]).to be(true)
        expect(response).to have_http_status(:success)
      end

      it 'creates assistants with nested response guidelines and guardrails' do
        attributes_with_nested_arrays = valid_attributes.deep_dup
        attributes_with_nested_arrays[:assistant][:response_guidelines] = [
          { title: 'Tone', body: 'Be concise' }
        ]
        attributes_with_nested_arrays[:assistant][:guardrails] = [
          { name: 'Safety', rule: 'Stay on topic' }
        ]

        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: attributes_with_nested_arrays,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        expect(response).to have_http_status(:success)
        expect(json_response[:response_guidelines]).to eq([{ title: 'Tone', body: 'Be concise' }.to_json])
        expect(json_response[:guardrails]).to eq([{ name: 'Safety', rule: 'Stay on topic' }.to_json])
      end

      it 'creates assistants with the standard humanlike voice defaults' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: valid_attributes,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        voice_settings = Captain::Assistant.order(:id).last.config['voice_settings']
        expect(voice_settings).to include(
          'humanlike_defaults_profile' => 'standard_v1',
          'provider' => 'gemini-live',
          'model' => 'gemini-3.1-flash-live-preview',
          'voice_activity_profile' => 'balanced',
          'interruptions_enabled' => true,
          'interruption_mode' => 'transcript_confirmed',
          'clear_audio_on_interrupt' => true,
          'finish_current_word_on_interrupt' => true,
          'turn_coverage' => 'TURN_INCLUDES_ONLY_ACTIVITY',
          'silence_prompt_enabled' => true,
          'tool_start_phrases' => ['Секунду, проверю.'],
          'tool_start_after_ms' => 1800,
          'tool_foreground_wait_ms' => 900,
          'emotional_style' => 'warm_professional',
          'nonverbal_cues_enabled' => true,
          'ambient_noise_enabled' => false
        )
        expect(json_response.dig(:config, :voice_settings, :humanlike_defaults_profile)).to eq('standard_v1')
      end

      it 'creates an assistant with feature_citation disabled' do
        attributes_with_disabled_citation = valid_attributes.deep_dup
        attributes_with_disabled_citation[:assistant][:config][:feature_citation] = false

        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: attributes_with_disabled_citation,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        expect(json_response[:config][:feature_citation]).to be(false)
        expect(response).to have_http_status(:success)
      end

      it 'creates an internal assistant when usage_mode is provided' do
        attributes_with_usage_mode = valid_attributes.deep_dup
        attributes_with_usage_mode[:assistant][:usage_mode] = 'internal_assistant'

        post "/api/v1/accounts/#{account.id}/captain/assistants",
             params: attributes_with_usage_mode,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:usage_mode]).to eq('internal_assistant')
        expect(Captain::Assistant.order(:id).last.usage_mode).to eq('internal_assistant')
      end

      it 'stores an explicit empty context_access on create' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: valid_attributes,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        created_assistant = Captain::Assistant.order(:id).last

        expect(created_assistant.config['context_access']).to eq({})
        expect(json_response.dig(:config, :context_access)).to eq({})
      end

      it 'stores tool_access when provided on create' do
        attributes_with_tool_access = valid_attributes.deep_dup
        attributes_with_tool_access[:assistant][:config][:tool_access] = {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          },
          assistant: {
            enabled: true,
            tool_ids: ['search_documentation']
          }
        }

        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: attributes_with_tool_access,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        created_assistant = Captain::Assistant.order(:id).last

        expect(created_assistant.config['tool_access']).to eq(
          'agent' => {
            'enabled' => true,
            'tool_ids' => ['faq_lookup']
          },
          'assistant' => {
            'enabled' => true,
            'tool_ids' => ['search_documentation']
          }
        )
      end

      it 'stores voice settings when provided on create' do
        attributes_with_voice_settings = valid_attributes.deep_dup
        attributes_with_voice_settings[:assistant][:config][:voice_settings] = {
          provider: 'gemini-live',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'sulafat',
          language: 'ru-KZ',
          voice_character_prompt: 'Тембр: тёплый эксперт-наставник, паузы короткие.',
          first_message: 'Сәлеметсіз бе!',
          max_duration_sec: 450,
          interruptions_enabled: false,
          voice_activity_profile: 'noisy',
          transfer_message: 'Қазір операторға қосамын.'
        }

        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: attributes_with_voice_settings,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        created_assistant = Captain::Assistant.order(:id).last

        expect(created_assistant.config['voice_settings']).to include(
          'provider' => 'gemini-live',
          'model' => 'gemini-3.1-flash-live-preview',
          'voice' => 'sulafat',
          'language' => 'ru-KZ',
          'voice_character_prompt' => 'Тембр: тёплый эксперт-наставник, паузы короткие.',
          'first_message' => 'Сәлеметсіз бе!',
          'interruptions_enabled' => false,
          'voice_activity_profile' => 'noisy',
          'speech_start_sensitivity' => 'START_SENSITIVITY_LOW',
          'speech_end_sensitivity' => 'END_SENSITIVITY_LOW',
          'vad_confidence' => 0.85,
          'vad_min_volume' => 0.7,
          'transfer_message' => 'Қазір операторға қосамын.'
        )
        expect(json_response.dig(:config, :voice_settings)).to include(
          provider: 'gemini-live',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'sulafat'
        )
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:update_attributes) do
      {
        assistant: {
          name: 'Updated Assistant',
          response_guidelines: ['Updated guideline'],
          guardrails: ['Updated guardrail'],
          config: {
            feature_citation: false
          }
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'does not update the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'does not update the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token,
              as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq('Updated Assistant')
        expect(json_response[:response_guidelines]).to eq(['Updated guideline'])
        expect(json_response[:guardrails]).to eq(['Updated guardrail'])
      end

      it 'updates prompt instructions up to the product limit' do
        long_description = 'а' * Captain::Assistant::DESCRIPTION_MAX_LENGTH

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { description: long_description } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.description).to eq(long_description)
      end

      it 'updates only response_guidelines when only that is provided' do
        assistant.update!(response_guidelines: ['Original guideline'], guardrails: ['Original guardrail'])
        original_name = assistant.name

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { response_guidelines: ['New guideline only'] } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq(original_name)
        expect(json_response[:response_guidelines]).to eq(['New guideline only'])
        expect(json_response[:guardrails]).to eq(['Original guardrail'])
      end

      it 'updates only guardrails when only that is provided' do
        assistant.update!(response_guidelines: ['Original guideline'], guardrails: ['Original guardrail'])
        original_name = assistant.name

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { guardrails: ['New guardrail only'] } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq(original_name)
        expect(json_response[:response_guidelines]).to eq(['Original guideline'])
        expect(json_response[:guardrails]).to eq(['New guardrail only'])
      end

      it 'updates feature_citation config' do
        assistant.update!(config: { 'feature_citation' => true })

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { config: { feature_citation: false } } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:config][:feature_citation]).to be(false)
      end

      it 'updates voice settings without replacing unrelated config sections' do
        assistant.update!(
          config: {
            'feature_faq' => true,
            'tool_access' => {
              'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] }
            },
            'voice_settings' => {
              'voice' => 'legacy-voice',
              'model' => 'legacy-model'
            }
          }
        )

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    voice_settings: {
                      provider: 'gemini-live',
                      model: 'gemini-3.1-flash-live-preview',
                      voice: 'sulafat',
                      language: 'ru-KZ',
                      voice_character_prompt: 'Тембр: тёплый эксперт-наставник, паузы короткие.',
                      first_message: 'Сәлеметсіз бе!',
                      max_duration_sec: 450,
                      interruptions_enabled: false,
                      transfer_message: 'Қазір операторға қосамын.'
                    }
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config).to include(
          'feature_faq' => true,
          'tool_access' => {
            'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] }
          }
        )
        expect(assistant.config['voice_settings']).to include(
          'provider' => 'gemini-live',
          'model' => 'gemini-3.1-flash-live-preview',
          'voice' => 'sulafat',
          'language' => 'ru-KZ',
          'voice_character_prompt' => 'Тембр: тёплый эксперт-наставник, паузы короткие.',
          'first_message' => 'Сәлеметсіз бе!',
          'interruptions_enabled' => false,
          'transfer_message' => 'Қазір операторға қосамын.'
        )
        expect(json_response.dig(:config, :voice_settings, :voice)).to eq('sulafat')
      end

      it 'discards unsupported voice settings keys' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    voice_settings: {
                      voice: 'sulafat',
                      tool_start_phrases: ['Секунду, проверю.'],
                      unsupported_runtime_option: 'unsafe'
                    }
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config['voice_settings']['voice']).to eq('sulafat')
        expect(assistant.config['voice_settings']['tool_start_phrases']).to eq(['Секунду, проверю.'])
        expect(assistant.config['voice_settings']).not_to have_key('unsupported_runtime_option')
      end

      it 'merges partial voice settings updates with existing settings and standard defaults' do
        assistant.update!(
          config: {
            'voice_settings' => {
              'voice' => 'legacy-voice',
              'language' => 'ru-KZ',
              'interruptions_enabled' => false
            }
          }
        )

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    voice_settings: {
                      voice: 'sulafat',
                      first_message: ''
                    }
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config['voice_settings']).to include(
          'humanlike_defaults_profile' => 'standard_v1',
          'voice' => 'sulafat',
          'language' => 'ru-KZ',
          'interruptions_enabled' => false,
          'first_message' => 'Здравствуйте! Чем могу помочь?',
          'clear_audio_on_interrupt' => true,
          'interruption_mode' => 'transcript_confirmed',
          'tool_foreground_wait_ms' => 900,
          'turn_coverage' => 'TURN_INCLUDES_ONLY_ACTIVITY'
        )
      end

      it 'preserves unrelated config sections when updating only feature flags' do
        assistant.update!(
          config: {
            'feature_faq' => true,
            'tool_access' => {
              'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff] }
            },
            'context_access' => {
              'contact' => { 'enabled' => true, 'field_ids' => ['contact.name'] }
            },
            'rules' => [
              {
                'id' => 'reply_short',
                'type' => 'response_guideline',
                'group' => 'Conversation flow',
                'content' => 'Reply briefly.',
                'enabled' => true
              }
            ]
          }
        )

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { config: { feature_faq: false } } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config).to include(
          'feature_faq' => false,
          'tool_access' => {
            'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff] }
          },
          'context_access' => {
            'contact' => { 'enabled' => true, 'field_ids' => ['contact.name'] }
          }
        )
        expect(assistant.config['rules']).to include(
          hash_including(
            'id' => 'reply_short',
            'type' => 'response_guideline',
            'content' => 'Reply briefly.'
          )
        )
      end

      it 'preserves tool and rules config when patching system settings only' do
        assistant.update!(
          config: {
            'temperature' => 1.0,
            'tool_access' => {
              'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff] }
            },
            'rules' => [
              {
                'id' => 'stay_focused',
                'type' => 'system',
                'group' => 'Strict rules',
                'content' => 'Stay focused.',
                'enabled' => true
              }
            ]
          }
        )

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    temperature: 0.4,
                    handoff_message_enabled: true,
                    handoff_message_mode: 'ai',
                    handoff_message: 'Escalating now.',
                    resolution_message_enabled: true,
                    resolution_message_mode: 'static'
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config).to include(
          'temperature' => 0.4,
          'handoff_message_enabled' => true,
          'handoff_message_mode' => 'ai',
          'handoff_message' => 'Escalating now.',
          'resolution_message_enabled' => true,
          'resolution_message_mode' => 'static',
          'tool_access' => {
            'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff] }
          }
        )
        expect(assistant.config['rules']).to include(
          hash_including(
            'id' => 'stay_focused',
            'type' => 'system',
            'content' => 'Stay focused.'
          )
        )
      end

      it 'updates usage_mode when the assistant is not connected to inboxes' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { usage_mode: 'internal_assistant' } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:usage_mode]).to eq('internal_assistant')
        expect(assistant.reload.usage_mode).to eq('internal_assistant')
      end

      it 'does not allow switching a connected assistant to internal mode' do
        create(:captain_inbox, captain_assistant: assistant, inbox: create(:inbox, account: account))

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { usage_mode: 'internal_assistant' } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('Internal assistants cannot be connected to channels')
        expect(assistant.reload.usage_mode).to eq('external_agent')
      end

      it 'allows clearing context_access to an explicit empty hash' do
        assistant.update!(config: { 'context_access' => { 'contact' => { 'enabled' => false, 'field_ids' => [] } } })

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { config: { context_access: {} } } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config['context_access']).to eq({})
        expect(json_response.dig(:config, :context_access)).to eq({})
      end

      it 'updates tool_access config' do
        assistant.update!(
          config: {
            'tool_access' => {
              'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] }
            }
          }
        )

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    tool_access: {
                      agent: {
                        enabled: false,
                        tool_ids: ['faq_lookup']
                      },
                      assistant: {
                        enabled: true,
                        tool_ids: ['search_documentation']
                      }
                    }
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config['tool_access']).to eq(
          'agent' => {
            'enabled' => false,
            'tool_ids' => ['faq_lookup']
          },
          'assistant' => {
            'enabled' => true,
            'tool_ids' => ['search_documentation']
          }
        )
      end

      # rubocop:disable RSpec/ExampleLength
      it 'updates structured rules config and syncs legacy rule lists' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    rules: [
                      {
                        id: 'clarify_first',
                        type: 'response_guideline',
                        group: 'Conversation flow',
                        content: 'Ask one clarifying question before proposing a solution.',
                        enabled: true
                      },
                      {
                        id: 'no_passwords',
                        type: 'guardrail',
                        group: 'Restrictions',
                        content: 'Never request passwords or verification codes.',
                        enabled: false
                      }
                    ]
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.response_guidelines).to eq(
          ['Ask one clarifying question before proposing a solution.']
        )
        expect(assistant.guardrails).to eq([])
        expect(assistant.config['rules']).to include(
          hash_including(
            'id' => 'clarify_first',
            'type' => 'response_guideline',
            'group' => 'Conversation flow',
            'content' => 'Ask one clarifying question before proposing a solution.',
            'enabled' => true
          ),
          hash_including(
            'id' => 'no_passwords',
            'type' => 'guardrail',
            'group' => 'Restrictions',
            'content' => 'Never request passwords or verification codes.',
            'enabled' => false
          )
        )
        expect(json_response.dig(:config, :rules)).to include(
          hash_including(
            id: 'clarify_first',
            type: 'response_guideline',
            group: 'Conversation flow',
            content: 'Ask one clarifying question before proposing a solution.',
            enabled: true
          ),
          hash_including(
            id: 'no_passwords',
            type: 'guardrail',
            group: 'Restrictions',
            content: 'Never request passwords or verification codes.',
            enabled: false
          )
        )
      end
      # rubocop:enable RSpec/ExampleLength

      # rubocop:disable RSpec/ExampleLength
      it 'keeps structured rules when updating them alongside the full config payload' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    rules: [
                      {
                        id: 'assistant_rule_inline',
                        type: 'response_guideline',
                        group: 'Conversation flow',
                        content: 'Reply with the short direct answer first.',
                        enabled: true
                      }
                    ],
                    feature_faq: true,
                    feature_memory: true,
                    feature_citation: true,
                    temperature: 1,
                    tool_access: {
                      agent: {
                        enabled: true,
                        tool_ids: %w[faq_lookup handoff add_contact_note add_private_note]
                      }
                    },
                    context_access: {},
                    handoff_message: '',
                    resolution_message: '',
                    history_message_limit: 0,
                    auto_reply_on_last_incoming: false,
                    message_collapse_window_seconds: 0
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.response_guidelines).to include(
          'Reply with the short direct answer first.'
        )
        expect(assistant.config['rules']).to include(
          hash_including(
            'id' => 'assistant_rule_inline',
            'type' => 'response_guideline',
            'group' => 'Conversation flow',
            'content' => 'Reply with the short direct answer first.',
            'enabled' => true
          )
        )
        expect(assistant.config['tool_access']).to eq(
          'agent' => {
            'enabled' => true,
            'tool_ids' => %w[faq_lookup handoff add_contact_note add_private_note]
          }
        )
        expect(json_response.dig(:config, :rules)).to include(
          hash_including(
            id: 'assistant_rule_inline',
            type: 'response_guideline',
            group: 'Conversation flow',
            content: 'Reply with the short direct answer first.',
            enabled: true
          )
        )
      end
      # rubocop:enable RSpec/ExampleLength

      it 'restores default system rules when the full config payload sends an empty rules array' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    rules: [],
                    feature_faq: false,
                    feature_memory: false,
                    feature_citation: false,
                    temperature: 0.4,
                    tool_access: {
                      agent: {
                        enabled: true,
                        tool_ids: %w[faq_lookup handoff add_contact_note add_private_note]
                      }
                    },
                    context_access: {},
                    handoff_message: '',
                    resolution_message: '',
                    history_message_limit: 15,
                    auto_reply_on_last_incoming: true,
                    message_collapse_window_seconds: 3
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.config['rules']).to include(
          hash_including(
            'id' => 'stay_within_scope',
            'type' => 'system',
            'enabled' => true,
            'editable' => false,
            'deletable' => false
          )
        )
        expect(json_response.dig(:config, :rules)).to include(
          hash_including(
            id: 'stay_within_scope',
            type: 'system',
            enabled: true,
            editable: false,
            deletable: false
          )
        )
      end

      it 'rejects malformed structured rules with a validation error' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: {
                assistant: {
                  config: {
                    rules: [
                      {
                        id: 'bad_rule',
                        type: 'guardrail',
                        group: 'Restrictions',
                        content: '   '
                      },
                      'not-a-rule'
                    ]
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('invalid')
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let!(:assistant) { create(:captain_assistant, account: account) }

    context 'when it is an un-authenticated user' do
      it 'does not delete the assistant' do
        delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
               as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'delete the assistant' do
        delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
               headers: agent.create_new_auth_token,
               as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the assistant' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end.to change(Captain::Assistant, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/assistants/{id}/avatar' do
    let(:assistant) { create(:captain_assistant, account: account) }

    context 'when it is an admin' do
      it 'uploads an avatar and returns avatar_url' do
        file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/avatar",
              params: { avatar: file },
              headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(assistant.reload.avatar).to be_attached
        expect(json_response[:avatar_url]).to be_present
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/assistants/{id}/avatar' do
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      assistant.avatar.attach(
        io: Rails.root.join('spec/assets/avatar.png').open,
        filename: 'avatar.png',
        content_type: 'image/png'
      )
    end

    context 'when it is an admin' do
      it 'deletes the avatar and returns a blank avatar_url' do
        delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/avatar",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(assistant.reload.avatar).not_to be_attached
        expect(json_response[:avatar_url]).to eq('')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/assistants/{id}/playground' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:valid_params) do
      {
        message_content: 'Hello assistant',
        message_history: [
          { role: 'user', content: 'Previous message' },
          { role: 'assistant', content: 'Previous response', agent_name: 'billing_scenario' }
        ]
      }
    end
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      before do
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(agent_runner_service)
        allow(agent_runner_service).to receive(:generate_response).and_return({ response: 'Assistant response' })
      end

      it 'generates a response with the agent runner service' do
        expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(agent_runner_service)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: valid_params[:message_history] + [{ role: 'user', content: valid_params[:message_content] }]
        )
        expect(json_response[:response]).to eq('Assistant response')
      end

      it 'uses empty array as default' do
        params_without_history = { message_content: 'Hello assistant' }

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: params_without_history,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: [{ role: 'user', content: params_without_history[:message_content] }]
        )
      end

      it 'does not duplicate the latest user message if it is already in history' do
        params_with_latest_message = {
          message_content: 'Hello assistant',
          message_history: [{ role: 'user', content: 'Hello assistant' }]
        }

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: params_with_latest_message,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: params_with_latest_message[:message_history]
        )
      end

      it 'passes an authorized conversation to the external agent runtime' do
        inbox = create(:inbox, account: account)
        conversation = create(:conversation, account: account, inbox: inbox)

        expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          conversation: conversation,
          source: 'playground'
        ).and_return(agent_runner_service)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params.merge(conversation_id: conversation.display_id),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
      end

      it 'rejects a conversation outside of the current account before starting the runtime' do
        other_account = create(:account)
        foreign_conversation = create(:conversation, account: other_account)

        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params.merge(conversation_id: foreign_conversation.display_id),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the assistant is an internal assistant' do
      let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'internal_assistant') }
      let(:chat_service) { instance_double(Captain::Copilot::ChatService) }

      it 'uses the employee copilot runtime with actor and non-duplicated history' do
        params_with_latest_message = {
          message_content: 'Hello assistant',
          message_history: [
            { role: 'assistant', content: 'Previous response', agent_name: 'billing_scenario' },
            { role: 'user', content: 'Hello assistant' }
          ]
        }
        allow(Captain::Copilot::ChatService).to receive(:new).with(
          assistant,
          {
            user_id: agent.id,
            previous_history: [{ role: 'assistant', content: 'Previous response' }],
            source: 'playground'
          }
        ).and_return(chat_service)
        allow(chat_service).to receive(:generate_response).with('Hello assistant').and_return(
          'content' => 'Copilot response',
          'reasoning' => 'Used account tools'
        )

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: params_with_latest_message,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to include(response: 'Copilot response', content: 'Copilot response')
      end
    end
  end
end
