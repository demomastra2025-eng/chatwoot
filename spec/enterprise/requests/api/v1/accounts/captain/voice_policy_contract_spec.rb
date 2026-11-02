require 'rails_helper'

RSpec.describe 'Platform voice policy contract', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, user: user, account: account, role: :administrator) } }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}" }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account) }
  let(:binding) { voice_channel.inbox.telephony_number_binding }
  let(:route_path) { "/api/v1/accounts/#{account.id}/telephony/numbers/#{binding.number_ref}/route" }
  let(:legacy) do
    { 'provider' => 'fish', 'model' => 'retired/voice', 'delegation_model' => 'retired/delegate', 'thinking_level' => 'high',
      'voice' => 'old-fish-id', 'system_prompt' => 'PRIVATE_VOICE_PROMPT', 'voice_character_prompt' => 'PRIVATE_CHARACTER',
      'archive' => { 'system_prompt' => 'PRIVATE_ARCHIVE' }, 'first_message' => 'Business greeting', 'language' => 'kk-KZ' }
  end

  def token_headers(user)
    { api_access_token: user.access_token.token }
  end

  before do
    account.enable_features!('channel_voice')
    allow(Llm::Config).to receive(:model_for).and_call_original
    allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return('platform/text-model')
    assistant.update!(config: assistant.config.merge('voice_settings' => legacy))
  end

  Telephony::AiVoice::PlatformPolicy::RETIRED_FIELDS.each do |field|
    it "rejects new #{field} overrides from both clinic and platform before any partial edit" do
      [admin, platform].each do |user|
        previous = assistant.reload.attributes.deep_dup
        patch path, params: { assistant: { name: 'Must not save', active: false, config: { voice_settings: { field => 'override' } } } },
                    headers: token_headers(user), as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to include('error' => 'platform_managed_voice_policy', 'fields' => ["config.voice_settings.#{field}"])
        expect(assistant.reload.attributes).to eq(previous)
      end
    end
  end

  it 'rejects new account voice overrides before filtering without mutating unrelated preferences' do
    cases = [{ captain_models: { voice: 'override' } },
             { captain_runtime: { voice_settings: { model: 'override' }, assistant_moderation: false } },
             { captain_runtime: { provider: 'openai-live', delegation_model: 'override', thinking_level: 'high' } }]
    [admin, platform].each do |user|
      cases.each do |attributes|
        saved = account.reload.settings.deep_dup
        put "/api/v1/accounts/#{account.id}/captain/preferences", params: attributes, headers: token_headers(user), as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('platform_managed_voice_policy')
        expect(response.parsed_body['fields']).not_to be_empty
        expect(account.reload.settings).to eq(saved)
      end
    end
  end

  it 'rejects new unknown voice IDs atomically while a stored legacy voice does not block unrelated saves' do
    [admin, platform].each do |user|
      saved = assistant.reload.attributes.deep_dup
      patch path, params: { assistant: { name: 'Must not save', config: { voice_settings: { voice: 'foreign-new-voice-id' } } } },
                  headers: token_headers(user), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'unsupported_voice', 'fields' => ['config.voice_settings.voice'])
      expect(assistant.reload.attributes).to eq(saved)
      patch path, params: { assistant: { name: 'Safe legacy rename' } }, headers: token_headers(user), as: :json
      expect(response).to have_http_status(:ok)
      expect(assistant.reload.config['voice_settings']).to eq(legacy)
    end
  end

  it 'keeps unrelated name/active/routing and business voice saves working with old fish keys intact' do
    patch path, params: { assistant: { name: 'Safe name', active: false, routing_description: 'Business routing',
                                       config: { voice_settings: { first_message: 'New greeting', interruptions_enabled: false } } } },
                headers: token_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    expect(assistant.reload).to have_attributes(name: 'Safe name', active: false, routing_description: 'Business routing')
    expect(assistant.config['voice_settings']).to include(legacy.except('first_message'))
    expect(assistant.config['voice_settings']).to include('first_message' => 'New greeting', 'interruptions_enabled' => false)
    expect(response.parsed_body.dig('config', 'voice_settings')).to include('provider' => 'gemini-live', 'voice' => 'sulafat')
  end

  it 'shares the same safe effective profile across API show/list, account tools and MCP for clinic roles' do
    [admin, agent].each do |user|
      [path, "/api/v1/accounts/#{account.id}/captain/assistants"].each do |url|
        get url, headers: token_headers(user), as: :json
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('PRIVATE_', 'retired/', 'old-fish-id')
        expect(response.body).to include('Business greeting', 'gemini-live')
      end
      tool = Captain::Tools::Account::GetCaptainAssistantService.new(assistant, user: user).execute(assistant_id: assistant.id)
      expect(tool.to_s).not_to include('PRIVATE_', 'retired/', 'old-fish-id')
      payload = { jsonrpc: '2.0', id: 'voice-read', method: 'resources/read', params: { uri: "onelink://accounts/#{account.id}/assistants" } }
      headers = { 'Authorization' => "Bearer #{user.access_token.token}", 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' }
      post "/api/v1/accounts/#{account.id}/mcp", params: payload.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('PRIVATE_', 'retired/', 'old-fish-id')
    end
  end

  it 'keeps GET/list and updates available with a missing delegation function, but denies actual preview before the provider' do
    allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return(nil)
    [path, "/api/v1/accounts/#{account.id}/captain/assistants"].each do |url|
      get url, headers: token_headers(platform), as: :json
      expect(response).to have_http_status(:ok)
    end
    patch path, params: { assistant: { name: 'Still editable' } }, headers: token_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    expect(Telephony::AiVoice::JanusSipRuntimeClient).not_to receive(:new)
    post "#{path}/voice_preview", headers: token_headers(platform), as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body['error']).to eq('voice_delegation_unavailable')
  end

  it 'denies actual preview for dashboard roles and API tokens before builder or credential/provider side effects' do
    expect(Telephony::AiVoice::PreviewContextBuilder).not_to receive(:new)
    expect(Telephony::AiVoice::JanusSipRuntimeClient).not_to receive(:new)
    [admin, agent].each do |user|
      [user.reload.create_new_auth_token, { api_access_token: user.access_token.token }].each do |headers|
        post "#{path}/voice_preview", params: { super_admin_impersonation: { actor_id: platform.id } }, headers: headers, as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it 'permits a verified impersonation preview, scopes it to the account and revokes it immediately' do
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: platform, account: account, target_user: admin)
    post '/auth/sign_in', params: { email: admin.email, sso_auth_token: grant.token }, as: :json
    headers = response.headers.slice('access-token', 'client', 'uid')
    expect(response.parsed_body.dig('data', 'captain_platform_access')).to be(true)
    preview = { 'token' => 'synthetic-token', 'expires_in' => 60, 'websocket_path' => '/synthetic-preview', 'private' => 'PRIVATE_RESPONSE' }
    client = instance_double(Telephony::AiVoice::JanusSipRuntimeClient, create_preview: preview)
    allow(Telephony::AiVoice::JanusSipRuntimeClient).to receive(:new).and_return(client)
    service = instance_double(Captain::Assistant::PromptPreviewService, preview: { assistant: { compiled_prompt: 'PRIVATE_COMPILED' } })
    allow(Captain::Assistant::PromptPreviewService).to receive(:new).with(assistant: assistant).and_return(service)
    post "#{path}/voice_preview", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(preview.except('private'))
    headers.merge!(response.headers.slice('access-token', 'client', 'uid'))
    expect(client).to have_received(:create_preview).with(hash_including(ai: hash_including('provider' => 'gemini-live',
                                                                                            'model' => 'gemini-3.1-flash-live-preview'))).once
    other = create(:account)
    create(:account_user, user: admin, account: other, role: :administrator)
    post "/api/v1/accounts/#{other.id}/captain/assistants/0/voice_preview", headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    SuperAdmin::ImpersonationService.revoke!(grant.client_id)
    post "#{path}/voice_preview", headers: headers, as: :json
    expect(response).not_to have_http_status(:ok)
    expect(client).to have_received(:create_preview).once
  end

  it 'rejects route and inbox technical writes before channel/policy mutation and preserves legacy during business edits' do
    binding.routing_policy.update!(ai_voice_settings: legacy)
    original = binding.routing_policy.reload.attributes.deep_dup
    [admin, platform].each do |user|
      post route_path, params: { mode: 'reject', ai_voice_settings: { provider: 'openai-live' } }, headers: token_headers(user), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('platform_managed_voice_policy')
      expect(binding.routing_policy.reload.attributes).to eq(original)
    end
    post route_path, params: { ai_voice_settings: { first_message: 'Updated business greeting' } }, headers: token_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    expect(binding.routing_policy.reload.ai_voice_settings).to eq(legacy.merge('first_message' => 'Updated business greeting'))
    expect(response.body).not_to include('PRIVATE_', 'old-fish-id', 'retired/')
  end

  it 'rejects inbox technical writes atomically for both actor types' do
    [admin, platform].each do |user|
      patch "/api/v1/accounts/#{account.id}/inboxes/#{voice_channel.inbox.id}",
            params: { name: 'Must not save', channel: { provider_config: { ai_voice_settings: { model: 'override' } } } },
            headers: token_headers(user), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('platform_managed_voice_policy')
      expect(voice_channel.inbox.reload.name).not_to eq('Must not save')
    end
  end

  it 'applies the same deny and partial-update contract to a real string-key account tool caller' do
    allow(Captain::Tools::ToolConfirmationGate).to receive(:new).and_return(instance_double(Captain::Tools::ToolConfirmationGate, call: nil))
    [admin, platform].each do |user|
      tool = Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: user)
      saved = assistant.reload.attributes.deep_dup
      result = tool.execute(assistant_id: assistant.id, name: 'Must not save', config_json: { voice_settings: { model: 'override' } }.to_json)
      expect(Captain::ToolResult.error?(result)).to be(true)
      expect(result[:data]).to eq(error: 'platform_managed_voice_policy', fields: ['config.voice_settings.model'])
      expect(assistant.reload.attributes).to eq(saved)
    end
    tool = Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: admin)
    result = tool.execute(assistant_id: assistant.id, config_json: { voice_settings: { system_prompt: 'Client prompt' } }.to_json)
    expect(result.to_s).to include('platform_managed_prompt')
    result = tool.execute(assistant_id: assistant.id, config_json: { voice_settings: { first_message: 'Tool business greeting' } }.to_json)
    expect(result.to_s).to include('Tool business greeting')
    expect(assistant.reload.config['voice_settings']).to eq(legacy.merge('first_message' => 'Tool business greeting'))
  end

  it 'round-trips the transport DTO without writing AI defaults or leaking transport secrets' do
    voice_channel.update!(provider_config: voice_channel.provider_config.merge(
      'ai_voice_settings' => legacy, 'beeline_api_token' => 'PRIVATE_TRANSPORT_SECRET', 'binotel_api_secret' => 'PRIVATE_TRANSPORT_SECRET'
    ))
    inbox_path = "/api/v1/accounts/#{account.id}/inboxes/#{voice_channel.inbox.id}"
    [admin, platform].each do |user|
      get inbox_path, headers: token_headers(user), as: :json
      transport = response.parsed_body.fetch('provider_config')
      expect(transport).not_to have_key('ai_voice_settings')
      expect(response.body).not_to include('PRIVATE_TRANSPORT_SECRET')
      patch inbox_path, params: { channel: { provider_config: transport.merge('sipuni_events_webhook_token' => 'synthetic-new-webhook') } },
                        headers: token_headers(user), as: :json
      expect(response).to have_http_status(:ok)
      expect(voice_channel.reload.provider_config['ai_voice_settings']).to eq(legacy)
      expect(voice_channel.provider_config['binotel_api_secret']).to eq('PRIVATE_TRANSPORT_SECRET')
    end
  end

  it 'projects legacy routing and inbox voice JSON through the verified actor policy' do
    config = voice_channel.provider_config.merge('ai_voice_settings' => legacy)
    voice_channel.update!(provider_config: config)
    urls = ["/api/v1/accounts/#{account.id}/telephony/numbers/#{binding.number_ref}", "/api/v1/accounts/#{account.id}/telephony/numbers",
            "/api/v1/accounts/#{account.id}/inboxes/#{voice_channel.inbox.id}"]
    [admin, platform].each do |user|
      urls.each do |url|
        get url, headers: token_headers(user), as: :json
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('PRIVATE_ARCHIVE', 'old-fish-id', 'retired/')
        expect(response.body.include?('PRIVATE_VOICE_PROMPT')).to eq(user == platform)
      end
    end
  end
end
