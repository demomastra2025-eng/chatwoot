require 'rails_helper'

RSpec.describe 'Assistant public read contract regression', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'internal_assistant', description: 'PRIVATE_CURRENT_PROMPT_MARKER') }

  def mcp_headers(user)
    { 'Authorization' => "Bearer #{user.access_token.token}", 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' }
  end

  it 'hides raw current prompts from MCP assistant resources for both clinic roles', :aggregate_failures do
    assistant
    [admin, agent].each do |user|
      payload = { jsonrpc: '2.0', id: 'review-resource', method: 'resources/read', params: { uri: "onelink://accounts/#{account.id}/assistants" } }
      post "/api/v1/accounts/#{account.id}/mcp", params: payload.to_json,
                                                 headers: mcp_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('PRIVATE_CURRENT_PROMPT_MARKER')
    end
  end

  it 'preserves platform prompt access in the MCP resource' do
    assistant
    request = { jsonrpc: '2.0', id: 'platform-resource', method: 'resources/read',
                params: { uri: "onelink://accounts/#{account.id}/assistants" } }
    post "/api/v1/accounts/#{account.id}/mcp", params: request.to_json,
                                               headers: mcp_headers(platform)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('PRIVATE_CURRENT_PROMPT_MARKER')
  end

  it 'hides archived prompt_history from the assistant JSON API and account tools', :aggregate_failures do
    # rubocop:disable Rails/SkipsModelValidations -- reproduce arbitrary historical persisted JSON
    assistant.update_column(:config, {
                              'prompt_history' => [{ 'description' => 'PRIVATE_ARCHIVED_PROMPT_MARKER' }],
                              'future_archive' => { 'description' => 'PRIVATE_ARCHIVED_PROMPT_MARKER' },
                              'voice_settings' => { 'future_archive' => { 'description' => 'PRIVATE_ARCHIVED_PROMPT_MARKER' },
                                                    'first_message' => { 'description' => 'PRIVATE_ARCHIVED_PROMPT_MARKER' } },
                              'context_access' => { 'contact' => { 'enabled' => true, 'field_ids' => ['contact.name'],
                                                                   'future_archive' => { 'description' => 'PRIVATE_ARCHIVED_PROMPT_MARKER' } } }
                            })
    # rubocop:enable Rails/SkipsModelValidations
    [admin, agent, platform].each do |user|
      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}", headers: user.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('PRIVATE_ARCHIVED_PROMPT_MARKER')
    end
    result = Captain::Tools::Account::GetCaptainAssistantService.new(assistant, user: admin).execute(assistant_id: assistant.id)
    expect(result.to_s).not_to include('PRIVATE_ARCHIVED_PROMPT_MARKER')
    expect(JSON.parse(result).dig('assistant', 'config', 'context_access', 'contact')).to eq('enabled' => true, 'field_ids' => ['contact.name'])
    expect(assistant.reload.config).to have_key('prompt_history')
  end
end
