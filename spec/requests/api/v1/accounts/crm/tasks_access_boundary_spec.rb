require 'rails_helper'

RSpec.describe 'CRM Tasks enforced access boundary', type: :request do
  let(:account) { create(:account) }
  let(:viewer) { create(:user, account: account, role: :agent) }
  let(:headers) { viewer.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks" }

  before do
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'paginates only tasks in the authoritative own scope' do
    own_tasks = create_list(:crm_task, 2, account: account, assignee: viewer)
    foreign_user = create(:user, account: account, role: :agent)
    foreign_task = create(:crm_task, account: account, assignee: foreign_user, title: 'Foreign scoped task')

    get path, params: { page: 1, per_page: 1 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    returned_ids = response.parsed_body.fetch('payload').pluck('id')
    expect(returned_ids.size).to eq(1)
    expect(returned_ids).to all(be_in(own_tasks.map(&:id)))
    expect(response.parsed_body.fetch('meta')).to include(
      'count' => 2,
      'page' => 1,
      'per_page' => 1,
      'has_more' => true
    )
    expect(response.parsed_body.to_json).not_to include(foreign_task.title)
  end

  it 'returns not found for a task and idempotency key outside the authoritative scope' do
    foreign_user = create(:user, account: account, role: :agent)
    foreign_task = create(
      :crm_task,
      account: account,
      assignee: foreign_user,
      idempotency_key: 'foreign-task-key'
    )

    get "#{path}/#{foreign_task.id}", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)

    post path,
         params: { title: 'Probe', assignee_id: viewer.id, idempotency_key: 'foreign-task-key' },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'caps per_page at the server maximum' do
    create(:crm_task, account: account, assignee: viewer)

    get path, params: { page: 1, per_page: 50_000 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'per_page')).to eq(500)
  end
end
