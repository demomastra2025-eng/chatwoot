# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AI Agents Report Custom Role Access', type: :request do
  it 'allows report_manage through native ReportPolicy without requiring CRM or inbox access' do
    account = create(:account)
    custom_role = create(:custom_role, account: account, permissions: ['report_manage'])
    member = create(:user)
    create(:account_user, user: member, account: account, role: :agent, custom_role: custom_role)

    get "/api/v1/accounts/#{account.id}/reports/ai_agents",
        params: { from_date: '2026-03-29', to_date: '2026-03-29' },
        headers: member.create_new_auth_token,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'totals', 'message_count')).to eq(0)
  end
end
