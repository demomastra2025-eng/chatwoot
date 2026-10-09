# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account Calls and Leads Reports API', type: :request do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:headers) { administrator.create_new_auth_token }
  let(:calls_path) { "/api/v1/accounts/#{account.id}/reports/calls" }
  let(:leads_path) { "/api/v1/accounts/#{account.id}/reports/leads" }
  let(:date_params) { { from_date: '2026-03-29', to_date: '2026-03-29' } }

  it 'serves account-scoped reports without requiring the CRM deals feature' do
    get calls_path, params: date_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'timezone')).to eq('Europe/Berlin')
    expect(response.parsed_body.dig('payload', 'summary', 'logical_call_count')).to eq(0)
    expect(response.parsed_body.dig('payload', 'coverage', 'complete')).to be(true)

    get leads_path, params: date_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'referrals', 'event_count')).to eq(0)
    expect(response.parsed_body.dig('payload', 'form_submissions', 'event_count')).to eq(0)
  end

  it 'rejects invalid report dates with a clear client error' do
    get calls_path,
        params: { from_date: '2026-02-30', to_date: '2026-03-01' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'INVALID_REPORT_RANGE',
      'error' => 'from_date must be a valid date'
    )
  end

  it 'requires report permission for both endpoints' do
    calls_agent = create(:user, account: account, role: :agent)
    leads_agent = create(:user, account: account, role: :agent)

    get calls_path, params: date_params, headers: calls_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:forbidden)

    get leads_path, params: date_params, headers: leads_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
