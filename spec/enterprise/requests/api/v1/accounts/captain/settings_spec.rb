require 'rails_helper'

RSpec.describe 'Captain account settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/settings" }

  it 'returns one account-level settings object to an administrator' do
    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.keys).to contain_exactly('understanding', 'handoff', 'faq', 'conversation', 'safety', 'availability')
    expect(body.dig('handoff', 'handoff_reasons')).to all(include('id', 'label', 'enabled', 'builtin'))
  end

  it 'accepts a partial patch without changing another section or an agent config' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_faq' => false })
    patch path, params: { faq: { generate_from_resolved: true }, handoff: { handoff_message: { mode: 'generated' } } },
                headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('handoff', 'handoff_message')).to include('mode' => 'generated', 'enabled' => true)
    expect(Captain::AccountSettings.new(account.reload).section('faq')['generate_from_resolved']).to be(true)
    expect(assistant.reload.config['feature_faq']).to be(false)
  end

  it 'rejects invalid custom rules with the exact errors envelope and leaves settings intact' do
    patch path, params: { safety: { custom_rules: [{ id: 'bad', direction: 'inbound', action: 'rewrite_once' }] } },
                headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors']).to include(include('field' => 'safety.custom_rules[0].action', 'code' => 'output_only'))
    expect(account.reload.captain_agent_settings).to be_nil
  end

  it 'requires administrator access for both reads and writes' do
    get path, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:forbidden)

    patch path, params: { faq: { generate_from_resolved: true } }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
