require 'rails_helper'

RSpec.describe 'CRM Pipelines API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/pipelines" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns unauthorized without auth' do
    get path, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'bootstraps default pipelines for administrators' do
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('sales_pipeline')
    expect(response.parsed_body.dig('payload', 0, 'stages').size).to eq(5)
  end

  it 'allows custom-role users with crm_settings_view' do
    custom_role = create(:custom_role, account: account, permissions: ['crm_settings_view'])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

    get path, headers: custom_role_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
  end

  it 'rejects plain agents from settings endpoints' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'creates a pipeline for administrators' do
    post path,
         params: { name: 'Enterprise Sales', code: 'enterprise_sales', default: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('enterprise_sales')
    expect(account.crm_pipelines.where(code: 'enterprise_sales')).to exist
  end

  it 'returns forbidden when crm_deals is disabled' do
    account.disable_features!('crm_deals')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
