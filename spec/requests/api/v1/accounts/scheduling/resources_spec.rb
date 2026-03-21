require 'rails_helper'

RSpec.describe 'Scheduling Resources API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, compensation_type: 'fixed', compensation_value: 5_000) }

  before do
    account.enable_features!('scheduling')
  end

  def response_body
    response.parsed_body
  end

  it 'updates a resource to fixed plus percent compensation without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            name: resource.name,
            specialty: resource.specialty,
            color: resource.color,
            timezone: resource.timezone,
            slot_duration_min: resource.slot_duration_min,
            compensation_type: 'fixed_plus_percent',
            compensation_value: 5_000,
            compensation_percent: 10,
            active: resource.active
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'compensation_type')).to eq('fixed_plus_percent')
    expect(response_body.dig('payload', 'compensation_percent')).to eq(10)
  end

  it 'updates work rules without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
          params: {
            work_rules: [
              { weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60, active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 0, 'weekday')).to eq(1)
  end

  it 'updates break rules without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/break_rules",
          params: {
            break_rules: [
              { weekday: 1, start_minute: 13 * 60, end_minute: 14 * 60, title: 'Lunch', active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 0, 'title')).to eq('Lunch')
  end

  it 'rejects deleting imported Medelement specialists' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
  end
end
