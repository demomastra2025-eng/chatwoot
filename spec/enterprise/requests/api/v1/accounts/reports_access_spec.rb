# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise Calls and Leads Reports API', type: :request do
  let(:account) { create(:account) }
  let(:custom_role) { create(:custom_role, account: account, permissions: ['report_manage']) }
  let(:report_manager) { create(:user) }

  before do
    create(:account_user, user: report_manager, account: account, role: :agent, custom_role: custom_role)
  end

  it 'allows a report_manage member to use the standalone reports without CRM deals enabled' do
    headers = report_manager.create_new_auth_token
    params = { from_date: '2026-03-01', to_date: '2026-03-01' }

    get "/api/v1/accounts/#{account.id}/reports/calls", params: params, headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    get "/api/v1/accounts/#{account.id}/reports/leads", params: params, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end
end
