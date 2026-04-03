require 'rails_helper'

RSpec.describe 'Scheduling Contacts API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/contacts" }

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  def response_body
    response.parsed_body
  end

  it 'creates contacts with a valid IIN and stores it as identifier' do
    post path,
         params: {
           full_name: 'Patient',
           phone: '+77015554433',
           iin: '940720300129'
         },
         headers:,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'identifier')).to eq('940720300129')
    expect(response_body.dig('payload', 'custom_attributes', 'iin')).to eq('940720300129')
  end

  it 'rejects invalid IIN values on create' do
    post path,
         params: {
           full_name: 'Patient',
           iin: '123456789012'
         },
         headers:,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('INVALID_IIN')
  end

  it 'rejects invalid IIN values on update' do
    contact = create(:contact, account: account, name: 'Patient')

    patch "#{path}/#{contact.id}",
          params: {
            iin: '123456789012'
          },
          headers:,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('INVALID_IIN')
  end

  it 'merges scheduling contact custom attributes on update' do
    contact = create(:contact, account: account, name: 'Patient', custom_attributes: { existing_key: 'existing value' })

    patch "#{path}/#{contact.id}",
          params: {
            birth_date: '1994-07-20',
            custom_attributes: { new_key: 'new value' }
          },
          headers:,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to eq(
      {
        'existing_key' => 'existing value',
        'new_key' => 'new value',
        'birth_date' => '1994-07-20'
      }
    )
    expect(contact.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end

  it 'initializes scheduling contact custom attributes when persisted value is nil' do
    contact = create(:contact, account: account, name: 'Patient')
    contact.update_columns(custom_attributes: nil)

    patch "#{path}/#{contact.id}",
          params: {
            custom_attributes: { new_key: 'new value' }
          },
          headers:,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'custom_attributes')).to eq(
      {
        'new_key' => 'new value'
      }
    )
    expect(contact.reload.custom_attributes).to eq(response_body.dig('payload', 'custom_attributes'))
  end
end
