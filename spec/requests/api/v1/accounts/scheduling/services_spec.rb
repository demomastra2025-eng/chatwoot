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

  it 'normalizes decimal zero service and price amounts' do
    put path,
        params: {
          base_price: '19000.0',
          prices: [
            {
              resource_id: resource.id,
              price: '21000.00',
              compensation_type: 'fixed_plus_percent',
              compensation_value: '3000.0',
              compensation_percent: '10.00',
              active: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    price = service.reload.prices.find_by!(resource_id: resource.id)
    expect(service.base_price).to eq(19_000)
    expect(price.price).to eq(21_000)
    expect(price.compensation_value).to eq(3_000)
    expect(price.compensation_percent).to eq(10)
  end

  it 'rejects fractional service price amounts without truncating them' do
    put path,
        params: {
          prices: [
            {
              resource_id: resource.id,
              price: '21000.50',
              compensation_type: 'percent',
              compensation_value: 40,
              compensation_percent: 0,
              active: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['error']).to eq('price must be an integer')
    expect(service.reload.prices.find_by(resource_id: resource.id)).to be_nil
  end

  it 'rejects manually assigning provider-owned service metadata' do
    post "/api/v1/accounts/#{account.id}/scheduling/services",
         params: {
           name: 'Spoofed provider service',
           custom_attributes: { medelement_nomenclature_code: 'spoofed-service' }
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
    expect(account.scheduling_services.where("custom_attributes ->> 'medelement_nomenclature_code' = ?", 'spoofed-service')).to be_empty
  end

  it 'deletes service prices before deleting the service' do
    create(:scheduling_service_price, account: account, service: service, resource: resource, price: 21_000)

    delete path, headers: headers, as: :json

    expect(response).to have_http_status(:no_content)
    expect(Scheduling::Service.exists?(service.id)).to be(false)
    expect(Scheduling::ServicePrice.where(service_id: service.id)).to be_empty
  end

  it 'rejects updating a provider-owned Medelement service' do
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })

    put path, params: { name: 'Changed locally' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('SERVICE_READ_ONLY')
    expect(service.reload.name).not_to eq('Changed locally')
  end

  it 'rejects deleting a provider-owned Medelement service' do
    service.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })

    delete path, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('SERVICE_READ_ONLY')
    expect(Scheduling::Service.exists?(service.id)).to be(true)
  end
end
