require 'rails_helper'

RSpec.describe 'CRM Task Statuses API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/task_statuses" }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'bootstraps default task statuses for administrators' do
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(3)
    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('todo')
  end

  it 'creates a task status for administrators' do
    post path,
         params: { name: 'Waiting for client', code: 'waiting_for_client', category: 'open' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('waiting_for_client')
  end

  it 'rejects plain agents from settings endpoints' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
