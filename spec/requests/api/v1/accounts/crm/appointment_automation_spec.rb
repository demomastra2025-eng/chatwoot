require 'rails_helper'

RSpec.describe 'CRM appointment automation API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:contact) { create(:contact, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/deals" }
  let(:deal) do
    create(:crm_deal, account: account).tap do |record|
      create(:crm_deal_contact, account: account, deal: record, contact: contact, primary: true)
    end
  end

  before { account.enable_features!('crm_deals', 'scheduling') }

  it 'automatically selects one active deal and requests a choice for several unless an explicit source is supplied' do
    deal
    get "#{path}/appointment_options", params: { contact_id: contact.id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'automatic_deal_id')).to eq(deal.id)
    other = create(:crm_deal, account: account)
    create(:crm_deal_contact, account: account, deal: other, contact: contact, primary: true)
    get "#{path}/appointment_options", params: { contact_id: contact.id }, headers: headers
    expect(response.parsed_body.dig('payload', 'requires_selection')).to be true
    expect(response.parsed_body.dig('payload', 'automatic_deal_id')).to be_nil
    get "#{path}/appointment_options", params: { contact_id: contact.id, source_deal_id: other.id }, headers: headers
    expect(response.parsed_body.dig('payload', 'automatic_deal_id')).to eq(other.id)
  end

  it 'does not expose an unrelated or foreign deal or contact through options' do
    deal
    other_contact = create(:contact, account: account)
    get "#{path}/appointment_options", params: { contact_id: other_contact.id, source_deal_id: deal.id }, headers: headers
    expect(response.parsed_body.dig('payload', 'deals')).to eq([])
    get "#{path}/appointment_options", params: { contact_id: create(:contact).id }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'returns cancelled linked appointments with independent honest attendance evidence' do
    visit = create(:scheduling_appointment, account: account, crm_deal: deal, status: 'cancelled')
    get "#{path}/#{deal.id}/appointments", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].first).to include('id' => visit.id, 'status' => 'cancelled', 'actual_attended' => false)
  end

  it 'requires a version to resume paused stage automation and records the explicit resume' do
    deal.update!(appointment_automation_state: { paused_at: Time.current.iso8601, manual_fingerprint: 'old' })
    post "#{path}/#{deal.id}/resume_appointment_automation", headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    post "#{path}/#{deal.id}/resume_appointment_automation", params: { lock_version: deal.reload.lock_version }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.appointment_automation_state['paused_at']).to be_nil
    expect(deal.events.last.meta['appointment_automation_resumed']).to be true
  end

  it 'rejects rules targeting a different pipeline and preserves incoming enablement during settings changes' do
    pipeline = deal.pipeline
    pipeline.update!(auto_create_deal_on_channel_contact: true)
    foreign_stage = create(:crm_stage, account: account)
    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}",
          params: { appointment_automation: { enabled: true, rules: [{ stage_id: foreign_stage.id, scope: 'any', conditions: ['scheduled'] }] } },
          headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}",
          params: { appointment_automation: { auto_create_from_calendar: true, cardinality: 'appointment' } },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(pipeline.reload.auto_create_deal_on_channel_contact).to be true
    expect(pipeline.appointment_automation['auto_create_from_calendar_enabled_at']).to be_present
  end
end
