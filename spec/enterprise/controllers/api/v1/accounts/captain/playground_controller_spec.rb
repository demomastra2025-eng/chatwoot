require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Playground', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:first_agent) { create(:captain_assistant, account: account) }
  let!(:second_agent) { create(:captain_assistant, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/playground" }
  let(:valid_params) { { message_content: 'Hello assistant' } }
  let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def runner_options(**extra)
    { scope: an_instance_of(Captain::ChannelScope), source: 'playground',
      playground_session: an_instance_of(Captain::Playground::Session) }.merge(extra)
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/playground' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized' do
        post path, params: valid_params, as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      before do
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(**runner_options).and_return(agent_runner_service)
        allow(agent_runner_service).to receive(:generate_response).and_return({ response: 'Assistant response' })
      end

      it 'tries out the whole AI of the workspace with no start agent' do
        scopes = []
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**options|
          scopes << options[:scope]
          agent_runner_service
        end

        post path, params: valid_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:response]).to eq('Assistant response')
        expect(scopes.size).to eq(1)
        expect(scopes.first).to have_attributes(kind: :workspace, inbox: nil)
        expect(scopes.first.members.map(&:id)).to contain_exactly(first_agent.id, second_agent.id)
      end

      it 'never offers an agent that is switched off' do
        second_agent.update!(active: false)
        scopes = []
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**options|
          scopes << options[:scope]
          agent_runner_service
        end

        post path, params: valid_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(scopes.first.members.map(&:id)).to eq([first_agent.id])
      end

      it 'builds the history of the run from the session' do
        expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(**runner_options).and_return(agent_runner_service)

        post path, params: valid_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: [{ role: 'user', content: valid_params[:message_content] }]
        )
      end

      it 'keeps one session per user and workspace; its key has no agent id' do
        post path, params: { playground_action: 'session' }, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        store = Captain::Playground::SessionStore.new(account: account, user: agent)
        expect(store.instance_variable_get(:@key)).to eq("captain:playground:v3:#{account.id}:#{agent.id}")
        expect(store.read(session_id: json_response.dig(:playground, :session_id))).to be_present
      end

      %i[inbox_id live_inbox_id].each do |param|
        it "records the channel sent as #{param} in the playground session" do
          inbox = create(:inbox, account: account)

          post path, params: { :playground_action => 'session', param => inbox.id }, headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
          store = Captain::Playground::SessionStore.new(account: account, user: agent)
          expect(store.read(session_id: json_response.dig(:playground, :session_id))['inbox_id']).to eq(inbox.id)
        end
      end

      it 'gives a text channel every enabled agent' do
        inbox = create(:inbox, account: account)
        scopes = []
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**options|
          scopes << options[:scope]
          agent_runner_service
        end

        post path, params: valid_params.merge(inbox_id: inbox.id), headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(scopes.first).to have_attributes(kind: :text)
        expect(scopes.first.members.map(&:id)).to contain_exactly(first_agent.id, second_agent.id)
      end

      it 'gives a voice channel the agent of that number alone' do
        voice_inbox = create_voice_inbox(account)
        create(:captain_inbox, inbox: voice_inbox, captain_assistant: second_agent)
        scopes = []
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**options|
          scopes << options[:scope]
          agent_runner_service
        end

        post path, params: valid_params.merge(inbox_id: voice_inbox.id), headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(scopes.first).to have_attributes(kind: :voice)
        expect(scopes.first.members.map(&:id)).to eq([second_agent.id])
      end

      it 'rejects a playground channel of another workspace' do
        post path, params: { playground_action: 'session', live_inbox_id: create(:inbox).id },
                   headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:error]).to eq('invalid_playground_scenario')
      end

      it 'rejects an unknown action' do
        post path, params: { playground_action: 'delete_everything' }, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:error]).to eq('invalid_playground_scenario')
      end

      it 'passes supported playground overrides to one runtime request without saving any agent' do
        original_configs = account.captain_assistants.order(:id).map { |item| item.config.deep_dup }
        requested_overrides = { model: 'openai/gpt-5.4', temperature: 0.4, thinking_effort: 'high' }
        allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return('openai/gpt-6-luna')
        allow(Llm::Models).to receive(:curated_model_names_for).with(:assistant, account: account)
                                                               .and_return(%w[openai/gpt-6-luna openai/gpt-5.4])
        allow(Llm::Models).to receive(:valid_model_for?).with(:assistant, 'openai/gpt-5.4', account: account).and_return(true)
        allow(Llm::Models).to receive(:supports_temperature?).with('openai/gpt-5.4', account: account).and_return(true)
        allow(Llm::Models).to receive(:supports_thinking?).with('openai/gpt-5.4', account: account).and_return(true)
        allow(Llm::Models).to receive(:reasoning_efforts_for).with('openai/gpt-5.4', account: account).and_return(['high'])
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(**runner_options(test_overrides: requested_overrides))
                                                                      .and_return(agent_runner_service)
        allow(agent_runner_service).to receive(:generate_response).and_return({ response: 'Test response' })

        post path, params: valid_params.merge(test_model: 'openai/gpt-5.4', test_temperature: 0.4, test_thinking_effort: 'high'),
                   headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(**runner_options(test_overrides: requested_overrides))
        expect(account.captain_assistants.order(:id).map(&:config)).to eq(original_configs)
      end

      it 'rejects temperature controls the default model does not advertise' do
        allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return('openai/gpt-6-luna')
        allow(Llm::Models).to receive(:supports_temperature?).with('openai/gpt-6-luna', account: account).and_return(false)
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post path, params: valid_params.merge(test_temperature: 0.4), headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_response).to eq(error: 'unsupported_playground_setting', field: 'test_temperature')
      end

      it 'passes zero and an advertised none override without persisting agent or workspace settings' do
        original_runtime = account.captain_runtime.deep_dup
        overrides = { temperature: 0.0, thinking_effort: 'none' }
        allow(Llm::Models).to receive(:supports_temperature?).and_return(true)
        allow(Llm::Models).to receive(:reasoning_efforts_for).and_return(%w[none high])
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(**runner_options(test_overrides: overrides))
                                                                      .and_return(agent_runner_service)

        post path, params: valid_params.merge(test_temperature: 0, test_thinking_effort: 'none'),
                   headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(**runner_options(test_overrides: overrides))
        expect(account.reload.captain_runtime).to eq(original_runtime)
      end

      it 'rejects none for models that cannot disable reasoning before starting the runtime' do
        allow(Llm::Models).to receive(:reasoning_efforts_for).and_return(%w[low medium high])
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post path, params: valid_params.merge(test_thinking_effort: 'none'), headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_response).to eq(error: 'unsupported_playground_setting', field: 'test_thinking_effort')
      end

      it 'rejects reasoning effort when the default model does not support reasoning' do
        allow(Llm::Models).to receive(:reasoning_efforts_for).and_return([])
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post path, params: valid_params.merge(test_thinking_effort: 'high'), headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_response).to eq(error: 'unsupported_playground_setting', field: 'test_thinking_effort')
      end

      it 'rejects a real conversation in Trial before starting the runtime' do
        inbox = create(:inbox, account: account)
        conversation = create(:conversation, account: account, inbox: inbox)

        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post path, params: valid_params.merge(conversation_id: conversation.display_id),
                   headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects a conversation outside of the current account before starting the runtime' do
        foreign_conversation = create(:conversation, account: create(:account))

        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post path, params: valid_params.merge(conversation_id: foreign_conversation.display_id),
                   headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
