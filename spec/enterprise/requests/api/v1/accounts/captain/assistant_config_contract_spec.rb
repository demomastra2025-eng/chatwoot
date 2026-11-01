require 'rails_helper'

RSpec.describe Captain::AssistantConfigContract, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Private platform instructions') }
  let(:admin_headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants" }

  def payload
    response.parsed_body
  end

  [false, true].each do |list|
    it "hides prompts from clinic users in #{list ? 'list' : 'show'} responses" do
      assistant
      [admin, agent].each do |user|
        get(list ? path : "#{path}/#{assistant.id}", headers: user.create_new_auth_token, as: :json)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Private platform instructions', '"description"')
      end
    end
  end

  it 'returns prompts to the platform team and permits a platform edit' do
    patch "#{path}/#{assistant.id}", params: { assistant: { description: 'Updated platform instructions' } },
                                     headers: platform.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['description']).to eq('Updated platform instructions')
    expect(assistant.reload.system_instruction).to eq('Updated platform instructions')
  end

  it 'permits platform read/write in a verified impersonation session' do
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: platform, account: account, target_user: admin)
    post '/auth/sign_in', params: { email: admin.email, sso_auth_token: grant.token }, as: :json
    headers = response.headers.slice('access-token', 'client', 'uid')

    patch "#{path}/#{assistant.id}", params: { assistant: { description: 'Impersonated platform instructions' } }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['description']).to eq('Impersonated platform instructions')
  end

  it 'rejects ordinary prompt writes atomically while preserving business metadata updates' do
    patch "#{path}/#{assistant.id}", params: { assistant: { description: 'Client instructions', active: false } },
                                     headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(payload).to include('error' => 'platform_managed_prompt', 'fields' => ['description'])
    expect(assistant.reload).to be_active

    patch "#{path}/#{assistant.id}", params: { assistant: { name: 'Business name', active: false } },
                                     headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assistant.reload).to have_attributes(name: 'Business name', active: false, description: 'Private platform instructions')
  end

  it 'rejects technical creation by a clinic and permits platform creation' do
    attributes = { assistant: { name: 'Configured agent', description: 'Platform instruction' } }
    post path, params: attributes, headers: admin_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(payload['error']).to eq('platform_managed_assistant')

    post path, params: attributes, headers: platform.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(payload['description']).to eq('Platform instruction')
  end

  Captain::AssistantConfigContract::UNSUPPORTED_FIELDS.each do |field|
    it "rejects ignored per-agent #{field} settings without partial mutation" do
      patch "#{path}/#{assistant.id}", params: { assistant: { name: 'Must not save', config: { field => false } } },
                                       headers: admin_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(payload).to include('error' => 'unsupported_assistant_settings', 'fields' => ["config.#{field}"])
      expect(assistant.reload.name).not_to eq('Must not save')
    end
  end

  it 'hides archived settings while reporting effective behavior without rewriting storage' do
    stored = { 'feature_memory' => true, 'history_message_limit' => 5, 'message_collapse_window_seconds' => 99,
               'thinking_effort' => 'high', 'temperature' => 1, 'model' => 'retired/model' }
    assistant.update_column(:config, stored) # rubocop:disable Rails/SkipsModelValidations -- reproduce a saved retired model
    allow(Llm::Config).to receive(:model_for).and_return('platform/model')

    get "#{path}/#{assistant.id}", headers: admin_headers, as: :json

    expect(payload['config']).not_to include(*stored.keys)
    expect(payload['effective_settings']).to include('model' => 'platform/model', 'feature_memory' => false, 'history_message_limit' => 40)
    expect(assistant.reload.config).to include(stored)

    patch "#{path}/#{assistant.id}", params: { assistant: { active: false } }, headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assistant.reload.config).to include(stored)
  end

  it 'rejects account model overrides for every conversational function' do
    put "/api/v1/accounts/#{account.id}/captain/preferences",
        params: { captain_models: { assistant: 'override', editor: 'override', copilot: 'override' } },
        headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(payload).to include('error' => 'installation_managed_models')
    expect(payload['fields']).to contain_exactly('assistant', 'editor', 'copilot')
  end

  it 'closes scenario instruction read/write paths while retaining metadata access' do
    scenario = create(:captain_scenario, assistant: assistant, account: account, instruction: 'Private scenario instruction')
    scenario_path = "#{path}/#{assistant.id}/scenarios/#{scenario.id}"
    get scenario_path, headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('Private scenario instruction', '"instruction"')

    patch scenario_path, params: { scenario: { instruction: 'Client instruction' } }, headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(payload['error']).to eq('platform_managed_prompt')
    expect(scenario.reload.instruction).to eq('Private scenario instruction')
  end

  it 'hides voice system instructions and rejects client voice prompt writes' do
    voice_settings = { 'system_prompt' => 'Private voice instructions', 'voice_character_prompt' => 'Private character' }
    assistant.update!(config: { 'voice_settings' => voice_settings })
    get "#{path}/#{assistant.id}", headers: admin_headers, as: :json
    expect(response.body).not_to include('Private voice instructions', 'Private character')

    patch "#{path}/#{assistant.id}", params: { assistant: { config: { voice_settings: { system_prompt: 'Client voice instructions' } } } },
                                     headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(payload).to include('error' => 'platform_managed_prompt', 'fields' => ['config.voice_settings.system_prompt'])
    expect(assistant.reload.config.dig('voice_settings', 'system_prompt')).to eq('Private voice instructions')
  end
end
