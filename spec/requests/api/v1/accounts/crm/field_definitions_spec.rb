require 'rails_helper'

RSpec.describe 'CRM Field Definitions API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/field_definitions" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'creates a field definition for deal custom fields' do
    post path,
         params: {
           entity_kind: 'deal',
           key: 'lead_source_code',
           label: 'Lead source',
           field_type: 'text',
           active: true
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'key')).to eq('lead_source_code')
  end

  it 'rejects keys that conflict with built-in fields' do
    post path,
         params: {
           entity_kind: 'deal',
           key: 'pipeline_id',
           label: 'Pipeline',
           field_type: 'text'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig('details', 'key')).to include('Key conflicts with a built-in field')
  end

  it 'filters definitions by entity_kind' do
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'deal_field')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'task_field')
    account.enable_features!('crm_tasks')

    get path, params: { entity_kind: 'deal' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'entity_kind')).to eq('deal')
  end

  it 'returns forbidden when neither crm_deals nor crm_tasks is enabled' do
    account.disable_features!('crm_deals')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
