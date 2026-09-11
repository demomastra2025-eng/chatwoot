require 'rails_helper'

RSpec.describe 'Scheduling Contacts API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/contacts" }
  let(:valid_phone) { "+7#{'7' * 10}" }
  let(:medelement_resource) do
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }
    )
  end

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  def response_body
    response.parsed_body
  end

  it 'loads one account-scoped contact by id with structured name fields' do
    target = create(
      :contact,
      account: account,
      name: 'Ivan',
      last_name: 'Ivanov',
      middle_name: 'Ivanovich'
    )
    create(:contact, account: account, name: 'Other')

    get path, params: { contact_id: target.id }, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response_body['payload']).to contain_exactly(
      hash_including(
        'id' => target.id,
        'first_name' => 'Ivan',
        'last_name' => 'Ivanov',
        'middle_name' => 'Ivanovich'
      )
    )
  end

  it 'creates contacts with a valid IIN and stores it as identifier' do
    post path,
         params: {
           first_name: 'Ivan',
           last_name: 'Ivanov',
           middle_name: 'Ivanovich',
           phone: valid_phone,
           iin: '940720300129'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created), response_body.inspect
    expect(response_body['payload']).to include(
      'first_name' => 'Ivan',
      'last_name' => 'Ivanov',
      'middle_name' => 'Ivanovich'
    )
    expect(response_body.dig('payload', 'identifier')).to eq('940720300129')
    expect(response_body.dig('payload', 'custom_attributes', 'iin')).to eq('940720300129')
    contact = Contact.find(response_body.dig('payload', 'id'))
    expect(EventDispatcherJob).to have_been_enqueued.with(
      'contact.created',
      anything,
      hash_including(contact: contact, performed_by: agent)
    )
  end

  it 'requires a last name when creating a contact' do
    post path,
         params: { first_name: 'Ivan', iin: '940720300129', resource_id: medelement_resource.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('CLIENT_LAST_NAME_REQUIRED')
  end

  it 'requires an IIN when creating a contact' do
    post path,
         params: { first_name: 'Ivan', last_name: 'Ivanov', resource_id: medelement_resource.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('IIN_REQUIRED')
  end

  it 'keeps ordinary scheduling contacts compatible without Medelement identity fields' do
    post path,
         params: { first_name: 'Ordinary', phone: valid_phone },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created), response_body.inspect
    expect(response_body.dig('payload', 'first_name')).to eq('Ordinary')
    expect(response_body.dig('payload', 'identifier')).to be_blank
  end

  it 'rejects invalid IIN values on create' do
    post path,
         params: {
           full_name: 'Patient',
           iin: '123456789012'
         },
         headers: headers,
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
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('INVALID_IIN')
  end

  it 'requires a last name on contact identity update' do
    contact = create(:contact, account: account, name: 'Patient', identifier: '940720300129')

    patch "#{path}/#{contact.id}",
          params: { first_name: 'Ivan', iin: '940720300129', resource_id: medelement_resource.id },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('CLIENT_LAST_NAME_REQUIRED')
  end

  it 'requires an IIN on contact identity update' do
    contact = create(:contact, account: account, name: 'Patient', last_name: 'Surname')

    patch "#{path}/#{contact.id}",
          params: { first_name: 'Ivan', last_name: 'Ivanov', resource_id: medelement_resource.id },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('IIN_REQUIRED')
  end

  it 'requires complete identity when updating an already provider-managed contact without a resource param' do
    contact = create(
      :contact,
      account: account,
      name: 'Patient',
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )

    patch "#{path}/#{contact.id}",
          params: { first_name: 'Ivan' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('IIN_REQUIRED')
  end

  it 'does not apply Medelement identity requirements to an ordinary contact update' do
    contact = create(:contact, account: account, name: 'Patient')

    patch "#{path}/#{contact.id}",
          params: { first_name: 'Updated' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok), response_body.inspect
    expect(contact.reload.name).to eq('Updated')
  end

  it 'rejects a resource from another account' do
    foreign_resource = create(:scheduling_resource)

    post path,
         params: { first_name: 'Patient', resource_id: foreign_resource.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
    expect(account.contacts.where(name: 'Patient')).to be_empty
  end

  it 'rejects manually assigning a provider-owned patient code' do
    post path,
         params: {
           full_name: 'Patient',
           custom_attributes: { medelement_patient_code: 'spoofed-patient' }
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
    expect(account.contacts.where("custom_attributes ->> 'medelement_patient_code' = ?", 'spoofed-patient')).to be_empty
  end

  it 'rejects manually assigning provider-derived contact attributes' do
    contact = create(
      :contact,
      account: account,
      name: 'Patient',
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )

    patch "#{path}/#{contact.id}",
          params: { custom_attributes: { address: 'spoofed provider address' } },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
    expect(contact.reload.custom_attributes).not_to have_key('address')
  end

  it 'allows ordinary contact attributes when the contact is not provider-managed' do
    contact = create(:contact, account: account, name: 'Patient')

    patch "#{path}/#{contact.id}",
          params: { custom_attributes: { address: 'Manual address' } },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(contact.reload.custom_attributes['address']).to eq('Manual address')
  end

  it 'merges scheduling contact custom attributes on update' do
    contact = create(:contact, account: account, name: 'Patient', custom_attributes: { existing_key: 'existing value' })

    patch "#{path}/#{contact.id}",
          params: {
            birth_date: '1994-07-20',
            custom_attributes: { new_key: 'new value' }
          },
          headers: headers,
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
          headers: headers,
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
