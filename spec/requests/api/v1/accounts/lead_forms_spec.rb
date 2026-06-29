require 'rails_helper'

RSpec.describe 'Lead Forms API', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('crm_deals') } }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:headers) { agent.create_new_auth_token }
  let(:inbox) { create(:inbox, account: account) }

  def response_body
    response.parsed_body
  end

  it 'creates and lists API lead forms' do
    post "/api/v1/accounts/#{account.id}/lead_forms",
         params: {
           name: 'Landing form',
           source_kind: 'api',
           inbox_id: inbox.id,
           field_schema: [{ name: 'full_name', label: 'Full name', type: 'text', required: true }]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'name')).to eq('Landing form')
    expect(response_body.dig('payload', 'public_token')).to be_present

    get "/api/v1/accounts/#{account.id}/lead_forms", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].pluck('name')).to include('Landing form')
  end

  it 'mirrors website widget pre-chat forms into the leads settings list' do
    inbox.channel.update!(pre_chat_form_enabled: true)

    get "/api/v1/accounts/#{account.id}/lead_forms", headers: headers, as: :json

    widget_form = response_body['payload'].find { |form| form['source_kind'] == 'widget' }
    expect(widget_form).to be_present
    expect(widget_form['inbox_id']).to eq(inbox.id)
    expect(widget_form.dig('settings', 'pre_chat_form_enabled')).to be(true)
  end

  it 'accepts public submissions and converts them into CRM intake records' do
    lead_form = create(:lead_form, account: account, inbox: inbox)

    post "/api/v1/lead_forms/#{lead_form.public_token}/submissions",
         params: {
           idempotency_key: 'web-1',
           field_values: {
             full_name: 'Website Lead',
             email: 'lead@example.com',
             phone_number: '+77001234567'
           }
         },
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'status')).to eq('processed')
    expect(account.lead_submissions.count).to eq(1)
    expect(account.conversations.count).to eq(1)
    expect(account.crm_deals.count).to eq(1)
  end

  it 'returns validation error when public submission misses required schema fields' do
    lead_form = create(
      :lead_form,
      account: account,
      inbox: inbox,
      field_schema: [{ name: 'fullName', label: 'Client name', type: 'text', required: true }]
    )

    post "/api/v1/lead_forms/#{lead_form.public_token}/submissions",
         params: {
           idempotency_key: 'web-missing-name',
           field_values: { comment: 'No name' }
         },
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['error']).to include('Client name')
  end
end
