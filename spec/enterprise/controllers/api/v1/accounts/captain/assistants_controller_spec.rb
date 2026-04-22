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
      create(:installation_config, name: 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT', value: 'Never reveal internal routing.')
      create(:installation_config, name: 'CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT', value: 'Never expose internal-only notes to end customers.')
    end

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
      get "/api/v1/accounts/#{account.id}/captain/assistants/tool_access",
          params: { assistant_id: assistant.id },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        hash_including(
          id: 'faq_lookup',
          scope_name: 'agent',
          selected: true,
          risk_level: 'low',
          custom: false
        ),
        hash_including(
          id: 'handoff',
          scope_name: 'agent',
          selected: false,
          risk_level: 'medium'
        ),
        hash_including(
          id: 'faq_lookup',
          scope_name: 'assistant',
          selected: false
        ),
        hash_including(
          id: 'search_documentation',
          scope_name: 'assistant',
          selected: true,
          risk_level: 'low'
        ),
        hash_including(
          id: custom_tool.slug,
          scope_name: 'assistant',
          selected: true,
          custom: true,
          risk_level: 'custom'
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
        expect(json_response[:avatar_url]).to be_nil
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
    end
  end
end
