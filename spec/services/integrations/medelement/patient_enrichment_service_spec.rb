require 'rails_helper'

RSpec.describe Integrations::Medelement::PatientEnrichmentService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(hook: hook, client: client) }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:patient_code) { '550990851604984873' }
  let(:search_patient) do
    {
      'PROFILE_CODE' => patient_code,
      'PATIENT_PHONE_2' => '+7-X-701-X-1234567'
    }
  end
  let(:patient) do
    {
      'PROFILE_CODE' => patient_code,
      'FULLNAME' => 'Иванова Анна Сергеевна',
      'LASTNAME' => 'Иванова',
      'NAME' => 'Анна',
      'MIDDLENAME' => 'Сергеевна',
      'PATIENT_PHONE_2_STR' => '+7 701 1234567'
    }
  end

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'enriches the existing contact for one exact patient match' do
    allow(client).to receive(:search_patients_by_phone).with(phone_number: '+77011234567').and_return([search_patient])
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient)

    resolved_contact = service.perform(contact)

    expect(resolved_contact.id).to eq(contact.id)
    expect(resolved_contact.name).to eq('Анна')
    expect(resolved_contact.last_name).to eq('Иванова')
    expect(resolved_contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
    expect(resolved_contact.custom_attributes['medelement_patient_match_status']).to eq('matched')
    expect(resolved_contact.custom_attributes['medelement_patient_phone_fingerprint']).not_to include('77011234567')
  end

  it 'caches an exact-phone miss without fetching a patient' do
    allow(client).to receive(:search_patients_by_phone).with(phone_number: '+77011234567').and_return([])
    allow(client).to receive(:get_patient)

    service.perform(contact)

    expect(client).not_to have_received(:get_patient)
    expect(contact.reload.custom_attributes['medelement_patient_match_status']).to eq('not_found')
  end

  it 'marks multiple exact matches as ambiguous without choosing a patient' do
    allow(client).to receive(:search_patients_by_phone).and_return([search_patient, search_patient.merge('PROFILE_CODE' => 'other')])
    allow(client).to receive(:get_patient)

    service.perform(contact)

    expect(client).not_to have_received(:get_patient)
    expect(contact.reload.custom_attributes['medelement_patient_match_status']).to eq('ambiguous')
  end

  it 'does not steal a patient code linked to another contact' do
    create(
      :contact,
      account: account,
      custom_attributes: { 'medelement_patient_code' => patient_code }
    )
    allow(client).to receive(:search_patients_by_phone).and_return([search_patient])
    allow(client).to receive(:get_patient)

    service.perform(contact)

    expect(client).not_to have_received(:get_patient)
    expect(contact.reload.custom_attributes['medelement_patient_match_status']).to eq('conflict')
  end

  it 'deduplicates a fresh lookup for the same phone fingerprint' do
    fingerprint = Digest::SHA256.hexdigest('+77011234567')
    contact.update!(
      custom_attributes: {
        'medelement_patient_lookup_at' => Time.current.iso8601,
        'medelement_patient_phone_fingerprint' => fingerprint,
        'medelement_patient_match_status' => 'not_found'
      }
    )
    allow(client).to receive(:search_patients_by_phone)

    service.perform(contact)

    expect(client).not_to have_received(:search_patients_by_phone)
  end

  it 'rejects a contact from another account' do
    foreign_contact = create(:contact, phone_number: '+77011234567')

    expect { service.perform(foreign_contact) }
      .to raise_error(ArgumentError, 'contact must belong to the integration account')
  end
end
