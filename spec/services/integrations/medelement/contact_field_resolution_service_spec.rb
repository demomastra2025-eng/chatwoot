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
  let(:updated_patient) { {} }
  let(:client) do
    instance_double(Integrations::Medelement::Client, get_patient: patient).tap do |double|
      allow(double).to receive(:update_patient) do |params:|
        updated_patient.replace(
          'PROFILE_CODE' => params['profile_code'],
          'NAME' => params['name'],
          'LASTNAME' => params['lastname'],
          'MIDDLENAME' => params['middlename'],
          'IIN' => params['iin'],
          'BIRTHDAY' => params['birthday'],
          'GENDER' => params['gender'],
          'PATIENT_EMAIL' => params['patient_email'],
          'PATIENT_PHONE_2_STR' => [
            params['patient_phone_2[0]'],
            params['patient_phone_2[1]'],
            params['patient_phone_2[2]']
          ].join
        )
      end
      allow(double).to receive(:search_patients_by_phone) { [updated_patient] }
    end
  end

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
    expect(conflict.reload).to have_attributes(
      status: 'open',
      details: hash_including(
        'conflicting_contact_id' => duplicate.id,
        'conflicting_field' => 'iin'
      )
    )
  end

  it 'normalizes a concurrent uniqueness failure into the structured collision response' do
    contact.update!(identifier: nil)
    duplicate = create(:contact, account: account, identifier: '950424301111')
    race_service_class = Class.new(described_class) do
      def ensure_unique_inbound_fields!(*); end

      def persist_provider_fields!(contact, *)
        contact.errors.add(:identifier, :taken)
        raise ActiveRecord::RecordInvalid, contact
      end
    end
    race_service = race_service_class.new(conflict: conflict, user: admin, client: client)

    expect do
      race_service.perform(field_directions: {
                             phone: 'onelink_to_medelement',
                             first_name: 'medelement_to_onelink',
                             iin: 'medelement_to_onelink'
                           })
    end.to raise_error(described_class::FieldAlreadyUsedError) { |error|
      expect(error).to have_attributes(field: 'iin', contact_id: duplicate.id)
    }

    expect(client).to have_received(:update_patient).once
    expect(Integrations::Medelement::ProviderCommand.last).to have_attributes(
      logical_status: 'reconciliation_required',
      last_error_code: 'contact_field_conflict'
    )
    expect(conflict.reload.details).to include(
      'conflicting_contact_id' => duplicate.id,
      'conflicting_field' => 'iin'
    )
  end

  it 'does not mask an unrelated validation error as a uniqueness collision' do
    contact.update!(identifier: nil)
    create(:contact, account: account, identifier: '950424301111')
    invalid_service_class = Class.new(described_class) do
      def ensure_unique_inbound_fields!(*); end

      def persist_provider_fields!(contact, *)
        contact.errors.add(:name, :blank)
        raise ActiveRecord::RecordInvalid, contact
      end
    end
    invalid_service = invalid_service_class.new(conflict: conflict, user: admin, client: client)

    expect do
      invalid_service.perform(field_directions: { iin: 'medelement_to_onelink' })
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(conflict.reload.details).not_to have_key('conflicting_contact_id')
  end

  it 'exposes the current phone owner for a safe merge after an inbound collision' do
    patient['PATIENT_PHONE_2_STR'] = '+77000007060'
    duplicate = create(:contact, account: account, phone_number: '+77000007060')

    expect do
      service.perform(field_directions: { phone: 'medelement_to_onelink' })
    end.to raise_error(described_class::FieldAlreadyUsedError)

    resolution = Integrations::Medelement::ConflictPresenter.new(conflict: conflict.reload).payload[:contact_resolution]
    expect(resolution).to include(
      can_merge: true,
      primary_contact: hash_including(id: contact.id),
      conflicting_contact: hash_including(id: duplicate.id)
    )
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

  it 'reconciles local persistence after the provider update succeeds' do
    failed_once = false
    allow(described_class).to receive(:apply_provider_command!).and_wrap_original do |method, command|
      unless failed_once
        failed_once = true
        raise ActiveRecord::StatementInvalid, 'injected resolution persistence failure'
      end

      method.call(command)
    end

    expect do
      service.perform(field_directions: { phone: 'onelink_to_medelement' })
    end.to raise_error(described_class::ResolutionError, /pending: executor_error/)

    command = Integrations::Medelement::ProviderCommand.last
    expect(command).to have_attributes(logical_status: 'reconciliation_required', last_error_code: 'executor_error')
    expect(conflict.reload).to be_open
    expect(client).to have_received(:update_patient).once

    command.update!(
      execution_state: command.execution_state.merge('reconciliation_next_at' => 1.minute.ago.iso8601)
    )

    service.perform(field_directions: { phone: 'onelink_to_medelement' })

    expect(command.reload).to be_succeeded
    expect(conflict.reload).to be_resolved
    expect(client).to have_received(:update_patient).once
  end

  it 'allows provider-only address values to update OneLink but not MedElement' do
    service.perform(field_directions: { address: 'medelement_to_onelink' })

    expect(contact.reload.custom_attributes['address']).to eq('Provider address')
    expect(client).not_to have_received(:update_patient)
  end
end
