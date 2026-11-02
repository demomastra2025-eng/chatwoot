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
    expect(payload.dig('data', 'captain_platform_access')).to be(true)
    headers = response.headers.slice('access-token', 'client', 'uid')

    patch "#{path}/#{assistant.id}", params: { assistant: { description: 'Impersonated platform instructions' } }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['description']).to eq('Impersonated platform instructions')
  end

  it 'publishes a server-derived platform flag for client controls without trusting local impersonation state' do
    get '/api/v1/profile', headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(payload['captain_platform_access']).to be(false)

    get '/api/v1/profile', headers: platform.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(payload['captain_platform_access']).to be(true)
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

  %w[
    model temperature thinking_effort feature_faq feature_memory feature_citation feature_web feature_document_reading
    feature_image_understanding use_audio_transcriptions handoff_enabled auto_completion_enabled auto_reply_on_last_incoming
    handoff_message handoff_message_enabled handoff_message_mode resolution_message resolution_message_enabled
    resolution_message_mode message_collapse_window_seconds history_message_limit safety_settings welcome_message
  ].each do |field|
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
               'thinking_effort' => 'high', 'temperature' => 1, 'model' => ' retired/model ' }
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

  it 'rejects account effort overrides for ordinary and platform administrators atomically' do
    [admin, platform].each do |user|
      original = account.reload.settings.deep_dup
      put "/api/v1/accounts/#{account.id}/captain/preferences",
          params: { captain_runtime: { assistant_thinking_effort: 'high', copilot_thinking_effort: 'high', assistant_moderation: true } },
          headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(payload).to include('error' => 'installation_managed_thinking_effort',
                                 'fields' => %w[captain_runtime.assistant_thinking_effort captain_runtime.copilot_thinking_effort])
      expect(account.reload.settings).to eq(original)
    end
  end

  actors = %i[admin platform]
  [{ unsupported_control: true }, { voice_settings: { unknown_setting: true } },
   { voice_settings: { first_message: { archive: 'raw' } } }, nil, []].each_with_index do |config, index|
    actors.each do |actor|
      it "rejects unknown or malformed config case #{index} for #{actor} before filtering or applying business edits" do
        original = assistant.attributes.deep_dup
        patch "#{path}/#{assistant.id}", params: { assistant: { name: 'Must not save', active: false, config: config } },
                                         headers: public_send(actor).create_new_auth_token, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(payload['error']).to eq('unsupported_assistant_settings')
        expect(payload['fields']).not_to be_empty
        expect(assistant.reload.attributes).to eq(original)
      end
    end
  end

  it 'protects follow-up technical instructions while retaining ordinary scheduling changes' do
    assistant.update!(config: { 'follow_up_settings' => { 'prompt' => 'Private follow-up instruction', 'enabled' => false, 'steps' => [] } })
    get "#{path}/#{assistant.id}", headers: admin_headers, as: :json
    expect(response.body).not_to include('Private follow-up instruction', '"prompt"')
    patch "#{path}/#{assistant.id}", params: { assistant: { config: { follow_up_settings: { prompt: 'Client prompt' } } } },
                                     headers: admin_headers, as: :json
    expect(payload).to include('error' => 'platform_managed_prompt', 'fields' => ['config.follow_up_settings.prompt'])
    expect(response).to have_http_status(:unprocessable_content)

    patch "#{path}/#{assistant.id}", params: { assistant: { name: 'Safe rename', active: false, routing_description: 'Billing',
                                                            config: { follow_up_settings: { enabled: false, steps: [] } } } },
                                     headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assistant.reload).to have_attributes(name: 'Safe rename', active: false, routing_description: 'Billing')
    expect(assistant.config.dig('follow_up_settings', 'prompt')).to eq('Private follow-up instruction')
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

  %w[tool_access capabilities].each do |field|
    it "keeps #{field} writes platform-only even before migration" do
      patch "#{path}/#{assistant.id}", params: { assistant: { config: { field => {} } } }, headers: admin_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(payload).to include('error' => 'platform_managed_capabilities', 'fields' => ["config.#{field}"])
    end
  end

  it 'updates a migrated canonical set atomically through the platform legacy alias and hides its provenance' do
    canonical = { 'version' => 1, 'scopes' => {
      'agent' => { 'enabled' => true, 'tool_ids' => ['add_private_note'] },
      'assistant' => { 'enabled' => false, 'tool_ids' => [] }
    } }
    assistant.update!(config: { 'capabilities' => canonical, 'tool_access' => { 'agent' => { 'tool_ids' => ['send_notification'] } },
                                'capabilities_migration' => { 'legacy_tool_access' => { 'private' => 'Private source marker' } } })
    patch "#{path}/#{assistant.id}", params: { assistant: { config: { tool_access: { agent: { tool_ids: ['add_contact_note'] } } } } },
                                     headers: platform.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(assistant.reload.allowed_agent_tool_ids).to include('add_contact_note')
    expect(assistant.allowed_agent_tool_ids).not_to include('send_notification', 'add_private_note')
    expect(assistant.config.dig('tool_access', 'agent', 'tool_ids')).to eq(['send_notification'])
    expect(payload['config']).not_to have_key('tool_access')
    expect(response.body).not_to include('Private source marker')
  end

  it 'protects the account transcription prompt from client reads and writes' do
    account.update!(captain_runtime: { 'audio_transcription_prompt' => 'Private transcription instructions' })
    preferences_path = "/api/v1/accounts/#{account.id}/captain/preferences"
    get preferences_path, headers: admin_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('Private transcription instructions')

    put preferences_path, params: { captain_runtime: { audio_transcription_prompt: 'Client instruction' } }, headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(payload).to include('error' => 'platform_managed_prompt', 'fields' => ['captain_runtime.audio_transcription_prompt'])
    expect(account.reload.captain_runtime['audio_transcription_prompt']).to eq('Private transcription instructions')
  end

  %w[test_model test_temperature test_thinking_effort].each do |field|
    it "rejects the #{field} Playground bypass before constructing the runtime" do
      expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)
      [admin, agent].each do |user|
        post "/api/v1/accounts/#{account.id}/captain/playground", params: { 'message_content' => 'Hello', field => 'override' },
                                                                  headers: user.reload.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(payload).to include('error' => 'unsupported_playground_setting', 'field' => field)
      end
    end
  end

  it 'does not restore archived scenario grants when a platform operator edits only its instructions' do
    scenario = create(:captain_scenario, assistant: assistant, account: account, instruction: 'Use [Note](tool://add_private_note).')
    result = Captain::LegacyScenarioConversionService.new.convert!(scenario.id)
    mapped = account.captain_assistants.find(result[:assistant_id])
    mapped.update!(config: mapped.config.merge('capabilities' => { 'version' => 1, 'scopes' => {
                                                 'agent' => { 'enabled' => true, 'tool_ids' => [] },
                                                 'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                                               } }))

    instructions = 'Platform edit [Note](tool://add_private_note).'
    patch "#{path}/#{assistant.id}/scenarios/#{scenario.id}", params: { scenario: { instruction: instructions } },
                                                              headers: platform.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(mapped.reload.config.dig('capabilities', 'scopes', 'agent', 'tool_ids')).to eq([])
    expect(mapped.allowed_agent_tool_ids).not_to include('add_private_note')
    expect(payload['tools']).to eq([])
    expect(scenario.reload.tools).to eq(['add_private_note'])
  end
end
