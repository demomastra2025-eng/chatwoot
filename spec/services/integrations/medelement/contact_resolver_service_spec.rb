require 'rails_helper'

RSpec.describe Integrations::Medelement::ContactResolverService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, client: client) }
  let(:patient_code) { '550990851604984873' }
  let(:patient_payload) do
    {
      'PROFILE_CODE' => patient_code,
      'FULLNAME' => 'Сулейменова Светлана Темирбаевна',
      'LASTNAME' => 'Сулейменова',
      'MIDDLENAME' => 'Темирбаевна',
      'BIRTHDAY' => '14.09.1972',
      'GENDER' => 1,
      'IIN' => '720914402646',
      'PATIENT_PHONE_2_STR' => '+7 701 5235543',
      'PATIENT_PHONE_3_STR' => '8 777 1112233',
      'PATIENT_EMAIL' => 'patient@example.com',
      'FULL_ADDRESS' => 'Almaty'
    }
  end

  it 'creates a contact and stores Medelement metadata' do
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.name).to eq('Сулейменова Светлана Темирбаевна')
    expect(contact.identifier).to eq('720914402646')
    expect(contact.phone_number).to eq('+77015235543')
    expect(contact.email).to eq('patient@example.com')
    expect(contact.additional_attributes['country_code']).to eq('KZ')
    expect(contact.additional_attributes['country']).to eq('Kazakhstan')
    expect(contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
    expect(contact.custom_attributes['secondary_phones']).to eq(['+77771112233'])
  end

  it 'does not overwrite a phone that already belongs to another contact' do
    create(:contact, account: account, phone_number: '+77015235543')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.phone_number).to be_blank
    expect(contact.custom_attributes['phone_conflict_comment']).to include('+77015235543')
    expect(contact.custom_attributes['secondary_phones']).to include('+77015235543')
  end

  it 'does not refresh a fresh contact' do
    contact = create(
      :contact,
      account: account,
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => Time.current.iso8601
      }
    )
    allow(client).to receive(:get_patient)

    resolved_contact = service.sync_patient!(patient_code)

    expect(client).not_to have_received(:get_patient)
    expect(resolved_contact.id).to eq(contact.id)
  end
end
