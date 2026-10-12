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

  describe 'birth date validation' do
    # The birth_date parameter is a plain date; a time part is refused as well.
    let(:invalid_dates) { %w[2026-02-30 2026-04-31 1990-13-40 1990-13-01 20.07.1994 not-a-date] + ['1990-03-05T00:00:00.000Z', '1990-03-05 10:30'] }
    let(:invalid_attribute_dates) do
      %w[2026-02-30 1990-13-40 1990-05-01T25:99:00Z 1990-05-01T00:00:00+99:99] + ['1990-05-01 00:00:00', '1990-05-01T99:99:99Z']
    end
    let!(:card) do
      create(:contact, account: account, name: 'Patient', custom_attributes: { 'birth_date' => '1994-07-20', 'keep' => 'me' })
    end

    it 'rejects a non-existent birth date on create without creating the contact' do
      invalid_dates.each do |value|
        expect do
          post path, params: { first_name: 'Ivan', phone: valid_phone, birth_date: value }, headers: headers, as: :json
        end.not_to change(Contact, :count)

        expect(response).to have_http_status(:unprocessable_content), value
        expect(response_body).to include('code' => 'INVALID_BIRTH_DATE')
        expect(response_body['error']).to include('birth_date')
        expect(response_body['details']).to eq('field' => 'birth_date', 'reason' => 'invalid_birth_date')
      end
    end

    it 'rejects a non-existent birth date sent inside custom_attributes on create' do
      expect do
        post path, params: { first_name: 'Ivan', phone: valid_phone, custom_attributes: { birth_date: '2026-02-30' } },
                   headers: headers, as: :json
      end.not_to change(Contact, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response_body).to include('code' => 'INVALID_BIRTH_DATE')
      expect(response_body['details']).to include('field' => 'custom_attributes.birth_date')
    end

    it 'rejects a non-existent birth date on update and leaves the card unchanged' do
      before_update = card.reload.attributes

      invalid_dates.each do |value|
        patch "#{path}/#{card.id}", params: { first_name: 'Changed', birth_date: value }, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content), value
        expect(response_body).to include('code' => 'INVALID_BIRTH_DATE')
        expect(response_body['error']).to include('birth_date')
        expect(card.reload.attributes).to eq(before_update)
      end
    end

    it 'rejects a non-existent birth date sent inside custom_attributes on update' do
      before_update = card.reload.attributes

      patch "#{path}/#{card.id}", params: { custom_attributes: { birth_date: '1990-13-40', other: 'x' } }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response_body).to include('code' => 'INVALID_BIRTH_DATE')
      expect(response_body['details']).to include('field' => 'custom_attributes.birth_date')
      expect(card.reload.attributes).to eq(before_update)
    end

    it 'rejects a birth date inside custom_attributes with an impossible time, UTC offset or a space instead of the T' do
      before_update = card.reload.attributes

      invalid_attribute_dates.each do |value|
        patch "#{path}/#{card.id}", params: { custom_attributes: { birth_date: value } }, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content), value
        expect(response_body).to include('code' => 'INVALID_BIRTH_DATE')
        expect(card.reload.attributes).to eq(before_update)
      end
    end

    it 'saves the dashboard time form inside custom_attributes' do
      patch "#{path}/#{card.id}", params: { custom_attributes: { birth_date: '1990-03-05T00:00:00.000Z' } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok), response_body.inspect
      expect(card.reload.custom_attributes['birth_date']).to eq('1990-03-05T00:00:00.000Z')
    end

    it 'accepts the value a legacy card already holds, so the card stays editable, but not a different bad one' do
      card.update!(custom_attributes: card.custom_attributes.merge('birth_date' => '2026-02-30'))

      patch "#{path}/#{card.id}", params: { first_name: 'Renamed', custom_attributes: { birth_date: '2026-02-30', other: 'x' } },
                                  headers: headers, as: :json
      expect(response).to have_http_status(:ok), response_body.inspect
      expect(card.reload.custom_attributes).to include('birth_date' => '2026-02-30', 'other' => 'x')

      patch "#{path}/#{card.id}", params: { custom_attributes: { birth_date: '2026-02-31' } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(card.reload.custom_attributes['birth_date']).to eq('2026-02-30')
    end

    it 'saves an existing date as before, including a leap day, and keeps the other attributes' do
      patch "#{path}/#{card.id}", params: { birth_date: '2024-02-29' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok), response_body.inspect
      expect(card.reload.custom_attributes).to eq('birth_date' => '2024-02-29', 'keep' => 'me')

      post path, params: { first_name: 'Ivan', phone: valid_phone, birth_date: '1990-03-05' }, headers: headers, as: :json
      expect(response).to have_http_status(:created), response_body.inspect
      expect(response_body.dig('payload', 'custom_attributes', 'birth_date')).to eq('1990-03-05')
    end

    it 'does not touch a stored birth date when an unrelated field is updated' do
      card.update!(custom_attributes: card.custom_attributes.merge('birth_date' => '2026-02-30'))

      patch "#{path}/#{card.id}", params: { first_name: 'Renamed' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok), response_body.inspect
      expect(card.reload).to have_attributes(name: 'Renamed')
      expect(card.custom_attributes['birth_date']).to eq('2026-02-30')
    end
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
