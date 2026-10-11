require 'rails_helper'

RSpec.describe 'Appointment CRM link result API', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:headers) { user.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:contact) { create(:contact, account: account) }
  let(:starts_at) { 2.days.from_now.in_time_zone(resource.timezone).change(hour: 10, min: 0, sec: 0) }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }
  let(:params) do
    { resource_id: resource.id, contact_id: contact.id, starts_at: starts_at.iso8601,
      duration_min: 30, idempotency_key: 'booking-with-optional-crm' }
  end

  before do
    account.enable_features!('scheduling', 'crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline.update!(appointment_automation: { auto_create_from_calendar: true })
    create(:crm_stage_field_requirement, stage: pipeline.stages.find_by!(default: true), field_key: 'description')
    create(:scheduling_work_rule, resource: resource, weekday: starts_at.wday)
  end

  it 'returns a persisted appointment and CRM warning on create, then replays the same booking without another appointment or deal' do
    post path, params: params, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    payload = response.parsed_body.fetch('payload')
    id = payload.fetch('id')
    expect(payload['crm_deal_id']).to be_nil
    expect(payload.fetch('crm_link_result')).to include('status' => 'not_linked', 'code' => 'DEAL_STAGE_REQUIRES_FIELDS')
    expect(account.scheduling_appointments.find(id)).to be_persisted
    expect(account.crm_deals).not_to exist

    expect do
      post path, params: params, headers: headers, as: :json
    end.not_to change(account.scheduling_appointments, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'id')).to eq(id)
    expect(response.parsed_body.dig('payload', 'crm_link_result')).to eq(payload['crm_link_result'])
    expect(account.crm_deals).not_to exist
  end

  it 'keeps an invalid explicit foreign deal selection as an error with no booking side effect' do
    foreign = create(:crm_deal)

    expect do
      post path, params: params.merge(crm_deal_id: foreign.id), headers: headers, as: :json
    end.not_to change(account.scheduling_appointments, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('CRM_DEAL_CONTACT_MISMATCH')
    expect(foreign.reload.appointments).not_to exist
  end
end
