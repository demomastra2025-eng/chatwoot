require 'rails_helper'

RSpec.describe Integrations::Medelement::ContactFieldResolutionService do
  subject(:service) { described_class.new(conflict: conflict, user: admin, client: client) }

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:hook) do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
  end
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Local',
      last_name: 'Patient',
      phone_number: '+77010007777',
      identifier: '950424301111',
      custom_attributes: {
        'medelement_patient_code' => 'patient-1',
        'medelement_first_name' => 'Provider',
        'medelement_last_name' => 'Patient',
        'medelement_middle_name' => 'Middle',
        'medelement_iin' => '950424301111',
        'medelement_birth_date' => '1995-04-24',
        'medelement_gender' => 'male',
        'phone_conflict_comment' => 'Medelement phone +77010007060 differs from the current Contact phone',
        'secondary_phones' => ['+77010007060']
      }
    )
  end
  let(:conflict) do
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_mismatch',
      entity_key: 'patient-1',
      details: { contact_id: contact.id }
    )
  end
  let(:patient) do
    {
      'PROFILE_CODE' => 'patient-1',
      'NAME' => 'Provider',
      'LASTNAME' => 'Patient',
      'MIDDLENAME' => 'Middle',
      'IIN' => '950424301111',
      'BIRTHDAY' => '1995-04-24',
      'GENDER' => '2',
      'PATIENT_EMAIL' => 'provider@example.com',
      'FULL_ADDRESS' => 'Provider address',
      'PATIENT_PHONE_2_STR' => '+77010007060'
    }
  end
  let(:client) { instance_double(Integrations::Medelement::Client, get_patient: patient, update_patient: {}) }

  before { account.enable_features!('scheduling') }

  it 'applies selected MedElement fields to OneLink and preserves the previous phone as secondary' do
    service.perform(field_directions: {
                      first_name: 'medelement_to_onelink',
                      phone: 'medelement_to_onelink'
                    })

    expect(contact.reload).to have_attributes(name: 'Provider', phone_number: '+77010007060')
    expect(contact.custom_attributes).to include('secondary_phones' => ['+77010007777'])
    expect(contact.custom_attributes).not_to have_key('phone_conflict_comment')
    expect(conflict.reload).to have_attributes(status: 'resolved', resolved_by: admin)
    expect(client).not_to have_received(:update_patient)
  end

  it 'sends only the selected OneLink values while preserving other provider identity fields' do
    service.perform(field_directions: { phone: 'onelink_to_medelement' })

    expect(client).to have_received(:update_patient).with(
      params: hash_including(
        'profile_code' => 'patient-1',
        'name' => 'Provider',
        'lastname' => 'Patient',
        'patient_phone_2[2]' => '0007777'
      )
    )
    expect(conflict.reload).to have_attributes(status: 'resolved', resolved_by: admin)
  end

  it 'rejects unsupported fields without mutating either side' do
    expect do
      service.perform(field_directions: { patient_code: 'medelement_to_onelink' })
    end.to raise_error(ArgumentError, 'Select at least one supported field direction')

    expect(contact.reload.phone_number).to eq('+77010007777')
    expect(conflict.reload).to be_open
    expect(client).not_to have_received(:update_patient)
  end

  it 'rejects a non-object field directions payload' do
    expect do
      service.perform(field_directions: 'phone=medelement_to_onelink')
    end.to raise_error(ArgumentError, 'Field directions must be an object')
  end

  it 'rejects outbound synchronization when provider writes are disabled' do
    hook.update!(settings: hook.settings.merge('write_enabled' => false))

    expect do
      service.perform(field_directions: { phone: 'onelink_to_medelement' })
    end.to raise_error(described_class::ResolutionError, 'MedElement writes are disabled for this integration')

    expect(client).not_to have_received(:update_patient)
    expect(conflict.reload).to be_open
  end

  it 'checks inbound unique fields before writing anything to MedElement' do
    contact.update!(identifier: nil)
    duplicate = create(:contact, account: account, identifier: '950424301111')

    expect do
      service.perform(field_directions: {
                        phone: 'onelink_to_medelement',
                        iin: 'medelement_to_onelink'
                      })
    end.to raise_error(described_class::FieldAlreadyUsedError) { |error|
      expect(error).to have_attributes(field: 'iin', contact_id: duplicate.id)
    }

    expect(client).not_to have_received(:update_patient)
    expect(contact.reload.identifier).to be_nil
    expect(conflict.reload).to be_open
  end

  it 'applies independent directions for different fields in one resolution' do
    service.perform(field_directions: {
                      first_name: 'medelement_to_onelink',
                      phone: 'onelink_to_medelement'
                    })

    expect(contact.reload.name).to eq('Provider')
    expect(client).to have_received(:update_patient).with(
      params: hash_including('patient_phone_2[2]' => '0007777')
    )
    expect(conflict.reload.resolution_note).to include(
      'first_name=medelement_to_onelink',
      'phone=onelink_to_medelement'
    )
  end

  it 'allows provider-only address values to update OneLink but not MedElement' do
    service.perform(field_directions: { address: 'medelement_to_onelink' })

    expect(contact.reload.custom_attributes['address']).to eq('Provider address')
    expect(client).not_to have_received(:update_patient)
  end
end
