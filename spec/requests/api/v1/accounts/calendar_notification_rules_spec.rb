require 'rails_helper'

RSpec.describe 'Calendar appointment notification rules', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/automation_rules" }
  let(:rule_params) do
    {
      name: 'Visit message', event_name: 'appointment_created', active: false, calendar_managed: true,
      conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
      actions: [{ action_name: 'create_touch', action_params: [{
        action_type: 'send_message', content_kind: 'free_text', body: 'Your visit is scheduled',
        timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: 0,
        target_inbox_id: create(:inbox, account: account).id
      }] }]
    }
  end

  it 'marks the rule and prevents editing it through the generic automation form' do
    post path, params: rule_params, headers: headers
    expect(response).to have_http_status(:success)
    rule = account.automation_rules.last
    expect(rule).to be_calendar_managed
    expect(rule.actions.first['action_params'].first['relative_offset_seconds'].to_i).to eq(0)

    put "#{path}/#{rule.id}", params: { active: true }, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(rule.reload).not_to be_active

    put "#{path}/#{rule.id}", params: { active: true, calendar_context: true }, headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload).to be_active
  end

  it 'returns an account-scoped appointment notification summary' do
    appointment = create(
      :scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)
    )
    reminder = create(:reminder, account: account, remindable: appointment)
    get "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/notifications", headers: headers

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['payload']).to include(include('id' => reminder.id, 'status' => 'draft'))
  end
end
