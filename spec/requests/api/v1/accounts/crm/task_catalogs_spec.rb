require 'rails_helper'

RSpec.describe 'CRM Task catalogs', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:types_path) { "/api/v1/accounts/#{account.id}/crm/task_types" }
  let(:outcomes_path) { "/api/v1/accounts/#{account.id}/crm/task_outcomes" }

  before do
    account.enable_features!('crm_deals')
    account.enable_features!('crm_tasks')
  end

  it 'returns the bootstrapped types with their configured outcomes' do
    get types_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    task_type = response.parsed_body.fetch('payload').find { |item| item['code'] == 'task' }
    expect(task_type).to include('name' => 'Task', 'active' => true, 'default' => true)
    expect(task_type.fetch('outcomes').pluck('code')).to include('completed', 'not_done', 'cancelled')
  end

  it 'creates and updates account-scoped task types and outcomes' do
    post types_path,
         params: { name: 'Demo', code: 'demo', icon: 'i-lucide-presentation', position: 20 },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    task_type = response.parsed_body.fetch('payload')

    post outcomes_path,
         params: {
           task_type_id: task_type.fetch('id'),
           name: 'Held',
           code: 'held',
           default: true,
           requires_note: true
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    outcome = response.parsed_body.fetch('payload')
    expect(outcome).to include(
      'task_type_id' => task_type.fetch('id'),
      'code' => 'held',
      'default' => true,
      'requires_note' => true
    )

    patch "#{outcomes_path}/#{outcome.fetch('id')}",
          params: { name: 'Completed demo' }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'name')).to eq('Completed demo')
  end

  it 'does not expose another account task type' do
    other_account = create(:account)
    other_account.enable_features!('crm_tasks')
    foreign_type = create(:crm_task_type, account: other_account)

    patch "#{types_path}/#{foreign_type.id}",
          params: { name: 'Changed' }, headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(foreign_type.reload.name).not_to eq('Changed')
  end
end
