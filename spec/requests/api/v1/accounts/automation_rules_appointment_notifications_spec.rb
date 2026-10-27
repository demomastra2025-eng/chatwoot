require 'rails_helper'

RSpec.describe 'Appointment automation notification rules', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:params) do
    {
      name: 'Visit notification', event_name: 'appointment_created', active: false,
      conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
      actions: [{ action_name: 'create_touch', action_params: [{
        body: 'Visit', timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -3600, scheduled_at: '', manual_schedule_override: true,
        timezone: 'Europe/Berlin'
      }] }]
    }
  end

  it 'normalizes old client timing on create, update, and clone' do
    post "/api/v1/accounts/#{account.id}/automation_rules", params: params, headers: admin.create_new_auth_token
    expect(response).to have_http_status(:success)
    rule = account.automation_rules.order(:id).last
    expect(rule.actions.first['action_params'].first).not_to have_key('manual_schedule_override')
    expect(rule.actions.first['action_params'].first['timezone']).to eq(account.workspace_working_hours_timezone)

    put "/api/v1/accounts/#{account.id}/automation_rules/#{rule.id}", params: params, headers: admin.create_new_auth_token
    expect(response).to have_http_status(:success)
    expect(rule.reload.actions.first['action_params'].first).not_to have_key('manual_schedule_override')

    post "/api/v1/accounts/#{account.id}/automation_rules/#{rule.id}/clone", headers: admin.create_new_auth_token
    expect(response).to have_http_status(:success)
    expect(account.automation_rules.order(:id).last.actions.first['action_params'].first['timezone']).to eq(
      account.workspace_working_hours_timezone
    )
  end
end
