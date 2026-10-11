require 'rails_helper'

RSpec.describe 'Captain agent channel settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:target) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}" }

  it 'accepts legacy handoff ids without changing the stored graph or exposing them' do
    assistant.update!(handoff_agent_ids: [target.id])

    patch path, headers: admin.create_new_auth_token, as: :json,
                params: { assistant: { routing_description: 'Billing', handoff_agent_ids: [] } }

    expect(response).to have_http_status(:success)
    expect(assistant.reload.handoff_agent_ids).to eq([target.id])
    expect(JSON.parse(response.body)).not_to have_key('handoff_agent_ids')
  end

  it 'accepts selected inbox ids and returns both selected and main channel ids' do
    patch path, headers: admin.create_new_auth_token, as: :json,
                params: { assistant: { channel_scope: 'selected', inbox_ids: [inbox.id] } }

    expect(response).to have_http_status(:success)
    expect(JSON.parse(response.body)).to include('channel_scope' => 'selected', 'inbox_ids' => [inbox.id], 'main_in_inbox_ids' => [])
  end

  it 'rejects deactivation of an enabled main agent with the channel ids' do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)

    patch path, headers: admin.create_new_auth_token, as: :json, params: { assistant: { active: false } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig('errors', 0)).to include('code' => 'MAIN_AGENT_IN_USE', 'inbox_ids' => [inbox.id])
    expect(assistant.reload).to be_active
  end

  it 'rejects deletion of an enabled main agent' do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)

    delete path, headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig('errors', 0, 'code')).to eq('MAIN_AGENT_IN_USE')
    expect(Captain::Assistant.exists?(assistant.id)).to be true
  end

  it 'rejects foreign channel selection without saving settings' do
    foreign_inbox = create(:inbox)

    patch path, headers: admin.create_new_auth_token, as: :json,
                params: { assistant: { name: 'Unsaved', channel_scope: 'selected', inbox_ids: [foreign_inbox.id] } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(assistant.reload.name).not_to eq('Unsaved')
  end
end
