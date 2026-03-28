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
    expect(response.parsed_body.dig('payload', 0, 'color')).to eq(Crm::TaskStatus::STANDARD_COLORS.first)
    expect(response.parsed_body.dig('payload', 1, 'code')).to eq('in_progress')
    expect(response.parsed_body.dig('payload', 1, 'category')).to eq('in_progress')
    expect(response.parsed_body.dig('payload', 1, 'color')).to eq(Crm::TaskStatus::STANDARD_COLORS.second)
  end

  it 'creates a task status for administrators' do
    post path,
         params: {
           name: 'Waiting for client',
           code: 'waiting_for_client',
           category: 'in_progress',
           color: '#3B82F6',
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('waiting_for_client')
    expect(response.parsed_body.dig('payload', 'category')).to eq('in_progress')
    expect(response.parsed_body.dig('payload', 'color')).to eq('#3B82F6')
  end

  it 'creates a task status with a russian name and auto-generated code' do
    post path,
         params: {
           name: 'В работе',
           category: 'in_progress',
           color: '#3B82F6',
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('в_работе')
    expect(response.parsed_body.dig('payload', 'category')).to eq('in_progress')
  end

  it 'allows administrators to persist explicit active state' do
    post path,
         params: {
           name: 'Paused',
           category: 'in_progress',
           color: '#3B82F6',
           active: false,
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'active')).to eq(false)
  end

  it 'deletes a task status without tasks for administrators' do
    task_status = create(:crm_task_status, account: account)

    delete "#{path}/#{task_status.id}", headers: headers, as: :json

    expect(response).to have_http_status(:no_content)
    expect(account.crm_task_statuses.exists?(task_status.id)).to be(false)
  end

  it 'rejects deleting a task status that still has tasks' do
    task_status = create(:crm_task_status, account: account)
    create(:crm_task, account: account, status: task_status)

    delete "#{path}/#{task_status.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('TASK_STATUS_HAS_TASKS')
  end

  it 'rejects plain agents from settings endpoints' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
