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
           color: '#3B82F6'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('waiting_for_client')
    expect(response.parsed_body.dig('payload', 'category')).to eq('in_progress')
    expect(response.parsed_body.dig('payload', 'color')).to eq('#3B82F6')
  end

  it 'allows duplicate standard colors for task statuses' do
    get path, headers: headers, as: :json
    existing_status = account.crm_task_statuses.find_by!(code: 'todo')

    post path,
         params: {
           name: 'Waiting for client',
           code: 'waiting_for_client',
           category: 'in_progress',
           color: existing_status.color
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'color')).to eq(existing_status.color)
    expect(account.crm_task_statuses.where(color: existing_status.color).count).to be >= 2
  end

  it 'switches the default status when creating another open default status' do
    get path, headers: headers, as: :json
    original_default = account.crm_task_statuses.find_by!(code: 'todo')

    post path,
         params: {
           name: 'Waiting for client',
           code: 'waiting_for_client',
           category: 'open',
           color: '#123456',
           default: true
         },
         headers: headers,
         as: :json

    new_default = account.crm_task_statuses.find_by!(code: 'waiting_for_client')

    expect(response).to have_http_status(:created)
    expect(new_default.default).to eq(true)
    expect(original_default.reload.default).to eq(false)
  end

  it 'switches the default status when updating an existing open status' do
    get path, headers: headers, as: :json
    original_default = account.crm_task_statuses.find_by!(code: 'todo')
    task_status = create(
      :crm_task_status,
      account: account,
      name: 'Waiting for client',
      code: 'waiting_for_client',
      category: 'open',
      color: '#123456',
      default: false,
      active: true
    )

    patch "#{path}/#{task_status.id}",
          params: { default: true },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(task_status.reload.default).to eq(true)
    expect(original_default.reload.default).to eq(false)
  end

  it 'creates a task status with a russian name and auto-generated code' do
    post path,
         params: {
           name: 'В работе',
           category: 'in_progress',
           color: '#3B82F6'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('в_работе')
    expect(response.parsed_body.dig('payload', 'category')).to eq('in_progress')
  end

  it 'creates a task status at the end when position is omitted' do
    get path, headers: headers, as: :json
    previous_last_position = account.crm_task_statuses.maximum(:position)

    post path,
         params: {
           name: 'Waiting for approval',
           category: 'open',
           color: '#14B8A6'
         },
         headers: headers,
         as: :json

    created_task_status = account.crm_task_statuses.find_by!(code: 'waiting_for_approval')

    expect(response).to have_http_status(:created)
    expect(created_task_status.position).to eq(previous_last_position + 1)
    expect(account.crm_task_statuses.ordered.last.id).to eq(created_task_status.id)
  end

  it 'allows administrators to persist explicit active state' do
    post path,
         params: {
           name: 'Paused',
           category: 'in_progress',
           color: '#3B82F6',
           active: false
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

  it 'allows plain agents to read task runtime references' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(3)
    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('todo')
  end

  it 'rejects plain agents from configuring task statuses' do
    post path,
         params: {
           name: 'Waiting for client',
           category: 'in_progress',
           color: '#3B82F6'
         },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(account.crm_task_statuses.where(code: 'waiting_for_client')).not_to exist
  end
end
