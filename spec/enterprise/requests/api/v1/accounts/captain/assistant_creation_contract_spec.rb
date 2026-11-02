require 'rails_helper'

RSpec.describe 'Canonical assistant creation', type: :request do
  let(:account) { create(:account) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants" }
  let(:description) { 'Use [Note](tool://add_private_note) and [Contact note](tool://add_contact_note).' }

  it 'starts API-created agents with empty canonical bindings despite standalone references' do
    post path, params: { assistant: { name: 'Platform agent', description: description } }, headers: platform.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    assistant = account.captain_assistants.find(response.parsed_body.fetch('id'))
    expect(assistant.config.fetch('capabilities')).to eq('version' => 1, 'scopes' => {
                                                           'agent' => { 'enabled' => true,
                                                                        'tool_ids' => [] }, 'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                                                         })
    expect(assistant.allowed_agent_tool_ids).to be_empty
    expect(assistant.prompt_runtime_agent_tools).to be_empty
    expect(assistant.voice_runtime_agent_tools).to be_empty
  end

  it 'converts only explicit platform selections in API creation, never the other references' do
    post path, params: { assistant: { name: 'Selected agent', description: description,
                                      config: { tool_access: { agent: { enabled: true, tool_ids: ['add_private_note'] } } } } },
               headers: platform.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    assistant = account.captain_assistants.find(response.parsed_body.fetch('id'))
    expect(assistant.allowed_agent_tool_ids).to eq(['add_private_note'])
    expect(assistant.config).not_to have_key('tool_access')
  end

  it 'initializes association and model creation paths identically without rewriting existing legacy rows' do
    direct = Captain::Assistant.create!(account: account, name: 'Direct model create', description: description)
    associated = account.captain_assistants.create!(name: 'Association create', description: description)
    expect(direct.config.fetch('capabilities')).to eq(associated.config.fetch('capabilities'))
    expect(direct.allowed_agent_tool_ids).to be_empty
    legacy = create(:captain_assistant, :legacy, account: account, description: description, config: {})
    legacy.update!(name: 'Business rename')
    expect(legacy.config).not_to have_key('capabilities')
    expect(legacy.description).to eq(description)
  end
end
