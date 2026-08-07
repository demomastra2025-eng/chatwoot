require 'rails_helper'

RSpec.describe Integrations::Medelement::ContactResolverService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, client: client) }
  let(:patient_code) { '550990851604984873' }
  let(:primary_phone) { ['+7', '701', '523', '5543'].join }
  let(:secondary_phone) { ['+7', '777', '111', '2233'].join }
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

  it 'creates a contact and stores Medelement metadata', :aggregate_failures do
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.name).to eq('Светлана')
    expect(contact.last_name).to eq('Сулейменова')
    expect(contact.custom_attributes).not_to have_key('medelement_middle_name')
    expect(contact.identifier).to eq('720914402646')
    expect(contact.phone_number).to eq(primary_phone)
    expect(contact.email).to eq('patient@example.com')
    expect(contact.additional_attributes['country_code']).to eq('KZ')
    expect(contact.additional_attributes['country']).to eq('Kazakhstan')
    expect(contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
    expect(contact.custom_attributes['secondary_phones']).to eq([secondary_phone])
  end

  it 'does not overwrite a phone that already belongs to another contact' do
    create(:contact, account: account, phone_number: primary_phone)
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.phone_number).to be_blank
    expect(contact.custom_attributes['phone_conflict_comment']).to include(primary_phone)
    expect(contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone, secondary_phone)
  end

  it 'keeps the Contact phone and surfaces a different provider phone for review' do
    contact_phone = ['+7', '700', '111', '2233'].join
    contact = create(:contact, account: account, phone_number: contact_phone)

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.phone_number).to eq(contact_phone)
    expect(resolved_contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone, secondary_phone)
    expect(resolved_contact.custom_attributes['phone_conflict_comment']).to include(primary_phone, 'current Contact phone')
  end

  it 'preserves local secondary phones while merging normalized provider phones' do
    local_secondary_phone = ['+7', '705', '222', '3344'].join
    contact = create(
      :contact,
      account: account,
      phone_number: primary_phone,
      custom_attributes: { 'secondary_phones' => [local_secondary_phone, '8 (777) 111-22-33'] }
    )

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.custom_attributes['secondary_phones']).to contain_exactly(
      local_secondary_phone,
      secondary_phone
    )
  end

  it 'accepts the Contact primary phone when it is a secondary provider phone' do
    contact = create(:contact, account: account, phone_number: secondary_phone)

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.phone_number).to eq(secondary_phone)
    expect(resolved_contact.custom_attributes['phone_conflict_comment']).to be_blank
    expect(resolved_contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone)
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
