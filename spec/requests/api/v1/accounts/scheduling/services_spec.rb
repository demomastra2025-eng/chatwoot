require 'rails_helper'

RSpec.describe 'Scheduling Services API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:headers) { agent.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:service) { create(:scheduling_service, account: account, base_price: 18_000) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/services/#{service.id}" }

  before do
    account.enable_features!('scheduling')
  end

  def response_body
    response.parsed_body
  end

  it 'defaults an active specialist price to the service base price when the price is blank' do
    put path,
        params: {
          prices: [
            {
              resource_id: resource.id,
              price: '',
              compensation_type: 'percent',
              compensation_value: 40,
              compensation_percent: 0,
              active: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'prices', 0, 'price')).to eq(18_000)
    expect(service.reload.prices.find_by!(resource_id: resource.id).price).to eq(18_000)
  end
end
