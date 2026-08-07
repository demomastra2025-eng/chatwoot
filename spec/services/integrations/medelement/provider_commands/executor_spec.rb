require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::Executor do
  subject(:perform) { executor.perform }

  let(:executor) { described_class.new(command: command) }

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Ivanov Ivan',
      phone_number: '+77001234567',
      custom_attributes: contact_custom_attributes
    )
  end
  let(:contact_custom_attributes) { {} }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
  end
  let(:appointment) { nil }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }
  let(:confirmation_status) { 'confirmed' }
  let(:confirmation_request) do
    create(
      :confirmation_request,
      account: account,
      conversation: nil,
      contact: contact,
      status: confirmation_status,
      resolved_at: confirmation_status == 'confirmed' ? Time.current : nil
    )
  end
  let(:operation) { 'create_patient' }
  let(:command_attributes) { {} }
  let(:command) do
    request_snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      company_cabinet_code: command_attributes[:company_cabinet_code],
      desired_starts_at: command_attributes[:desired_starts_at],
      desired_ends_at: command_attributes[:desired_ends_at]
    ).build
    request_fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(request_snapshot)
    request_execution_state = {
      'request_snapshot' => request_snapshot,
      'request_fingerprint' => request_fingerprint,
      'confirmation_request_id' => confirmation_request.id
    }
    record = Integrations::Medelement::ProviderCommand.create!(
      {
        account: account,
        hook: hook,
        appointment: appointment,
        contact: contact,
        confirmation_request: confirmation_request,
        operation: operation,
        status: 'queued',
        confirmed_at: Time.current,
        idempotency_key: SecureRandom.uuid,
        execution_state: request_execution_state
      }.merge(command_attributes)
    )
    confirmation_request.update!(
      metadata: {
        'medelement_provider_command_id' => record.id,
        'operation' => record.operation,
        'request_fingerprint' => request_fingerprint
      }
    )
    record
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
  end

  context 'when confirmation is no longer confirmed' do
    let(:confirmation_status) { 'pending' }

    it 'fails closed before constructing a provider client' do
      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'execution_gate_closed', attempt_count: 1)
      expect(Integrations::Medelement::Client).not_to have_received(:new)
    end
  end

  context 'when the confirmed request snapshot is invalid' do
    it 'fails closed before constructing a provider client' do
      command.execution_state['request_snapshot']['operation'] = 'update_patient'
      command.save!

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'request_snapshot_invalid')
      expect(Integrations::Medelement::Client).not_to have_received(:new)
    end
  end

  context 'when the confirmation binding is invalid after queueing' do
    it 'fails closed before constructing a provider client' do
      command
      confirmation_request.update!(metadata: confirmation_request.metadata.merge('operation' => 'update_patient'))

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'confirmation_snapshot_invalid')
      expect(Integrations::Medelement::Client).not_to have_received(:new)
    end
  end

  context 'when creating a patient' do
    it 'requires explicit selection for one phone-only provider match' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }]
      )
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(
        status: 'awaiting_patient_selection',
        provider_patient_code: nil,
        last_error_code: 'patient_selection_required'
      )
      expect(command.execution_state['patient_action']).to include('candidate_count' => 1)
      expect(contact.reload.custom_attributes['medelement_patient_code']).to be_nil
      expect(client).not_to have_received(:create_patient)
    end

    it 'requires explicit selection for the only identity match among patients sharing a phone' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [
          { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Other', 'LASTNAME' => 'Person' },
          { 'PROFILE_CODE' => 'patient-2', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' },
          { 'PROFILE_CODE' => 'patient-3', 'NAME' => 'Family', 'LASTNAME' => 'Member' }
        ]
      )
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'awaiting_patient_selection', provider_patient_code: nil)
      expect(command.execution_state['patient_action']).to include('candidate_count' => 1)
      expect(client).not_to have_received(:create_patient)
    end

    it 'searches every snapshotted Contact phone and deduplicates candidates by patient code' do
      secondary_phone = ['+7', '777', '111', '2233'].join
      contact.update!(custom_attributes: { 'secondary_phones' => [secondary_phone] })
      patient = { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }
      allow(client).to receive(:search_patients_by_phone).with(phone_number: contact.phone_number).and_return([patient])
      allow(client).to receive(:search_patients_by_phone).with(phone_number: secondary_phone).and_return([patient])
      allow(client).to receive(:create_patient)

      perform

      expect(command.request_snapshot.dig('patient', 'phone_numbers')).to eq([contact.phone_number, secondary_phone])
      expect(command.reload).to have_attributes(status: 'awaiting_patient_selection')
      expect(command.execution_state['patient_action']).to include('candidate_count' => 1)
      expect(client).not_to have_received(:create_patient)
    end

    it 'requires explicit creation when phone candidates do not match the middlename' do
      contact.update!(name: 'Ivanov Ivan Ivanovich')
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov', 'MIDDLENAME' => 'Petrovich' }]
      )
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'awaiting_patient_creation')
      expect(command.execution_state['patient_action']).to include('can_confirm' => false)
      expect(client).not_to have_received(:create_patient)
    end

    it 'gives an exact IIN match precedence over different names and birthday' do
      contact.update!(custom_attributes: { 'medelement_iin' => '940720300129' })
      patient = { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Other', 'LASTNAME' => 'Person', 'IIN' => '940720300129',
                  'BIRTHDAY' => '01.01.2000', 'PATIENT_PHONE_2' => contact.phone_number }
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return(
        [patient, patient.dup]
      )
      allow(client).to receive(:search_patients_by_phone)
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload.provider_patient_code).to eq('patient-1')
      expect(client).not_to have_received(:search_patients_by_phone)
      expect(client).not_to have_received(:create_patient)
    end

    it 'persists an exact-IIN patient code before waiting for phone refresh' do
      contact.update!(custom_attributes: { 'medelement_iin' => '940720300129' })
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'IIN' => '940720300129',
           'PATIENT_PHONE_2' => ['+7', '700', '999', '8877'].join }]
      )

      perform

      expect(command.reload).to have_attributes(
        status: 'awaiting_phone_refresh',
        provider_patient_code: 'patient-1'
      )
      expect(contact.reload.custom_attributes).to include(
        'medelement_patient_code' => 'patient-1',
        'iin' => '940720300129'
      )
    end

    it 'stops before provider lookup when another Contact already owns the same IIN identity' do
      contact.update!(custom_attributes: { 'medelement_iin' => '940720300129' })
      create(
        :contact,
        account: account,
        identifier: '940720300129',
        custom_attributes: { 'medelement_patient_code' => 'patient-owner' }
      )
      allow(client).to receive(:search_patients_by_iin)
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'patient_identity_conflict')
      expect(client).not_to have_received(:search_patients_by_iin)
      expect(client).not_to have_received(:create_patient)
    end

    it 'requires explicit creation when the requested birthday differs' do
      contact.update!(custom_attributes: { 'medelement_birth_date' => '1994-07-20' })
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov', 'BIRTHDAY' => '21.07.1994' }]
      )
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'awaiting_patient_creation')
      expect(client).not_to have_received(:create_patient)
    end

    it 'does not create a remote patient before a separate creation confirmation' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [
          { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Other', 'LASTNAME' => 'Person' },
          { 'PROFILE_CODE' => 'patient-2', 'NAME' => 'Family', 'LASTNAME' => 'Member' }
        ]
      )
      allow(client).to receive(:create_patient)
      contact
      contact_count = account.contacts.count

      perform

      expect(command.reload).to have_attributes(status: 'awaiting_patient_creation', provider_patient_code: nil)
      expect(contact.reload.custom_attributes['medelement_patient_code']).to be_nil
      expect(account.contacts.count).to eq(contact_count)
      expect(client).not_to have_received(:create_patient)
    end

    it 'waits for an explicit patient selection before a write' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [
          { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' },
          { 'PROFILE_CODE' => 'patient-2', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }
        ]
      )
      allow(client).to receive(:create_patient)

      expect { perform }.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)

      expect(command.reload).to have_attributes(
        status: 'awaiting_patient_selection',
        last_error_code: 'patient_selection_required'
      )
      expect(command.execution_state['patient_action']).to include('candidate_count' => 2)
      expect(command.execution_state).not_to include('write_phase')
      expect(client).not_to have_received(:create_patient)
    end

    it 'reads back a created patient and synchronizes provider data into the contact' do
      contact.update!(
        name: 'Ivanov Ivan Ivanovich',
        custom_attributes: { 'medelement_iin' => '940720300129' }
      )
      command.update!(execution_state: command.execution_state.merge('patient_creation_confirmed' => true))
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').twice.and_return([])
      allow(client).to receive(:create_patient).and_return('profile_code' => 'patient-created')
      allow(client).to receive(:get_patient).with(patient_code: 'patient-created').and_return(
        'PROFILE_CODE' => 'patient-created',
        'NAME' => 'Ivan',
        'LASTNAME' => 'Ivanov',
        'MIDDLENAME' => 'Ivanovich',
        'IIN' => '940720300129',
        'PATIENT_PHONE_2' => contact.phone_number
      )

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-created')
      expect(contact.reload.custom_attributes).to include(
        'medelement_patient_code' => 'patient-created',
        'medelement_patient_match_status' => 'matched'
      )
      expect(client).to have_received(:get_patient).with(patient_code: 'patient-created').once
    end

    it 'requires reconciliation when a created patient cannot be read back' do
      contact.update!(
        name: 'Ivanov Ivan Ivanovich',
        custom_attributes: { 'medelement_iin' => '940720300129' }
      )
      command.update!(execution_state: command.execution_state.merge('patient_creation_confirmed' => true))
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return([], [], [])
      allow(client).to receive(:create_patient).and_return('profile_code' => 'patient-created')
      allow(client).to receive(:get_patient).with(patient_code: 'patient-created').and_return(nil)

      perform

      expect(command.reload).to have_attributes(
        status: 'reconciliation_required',
        last_error_code: 'patient_create_readback_missing'
      )
    end

    it 'uses exact IIN and returned code when direct created-patient readback is unavailable' do
      contact.update!(
        name: 'Ivanov Ivan Ivanovich',
        custom_attributes: { 'medelement_iin' => '940720300129' }
      )
      command.update!(execution_state: command.execution_state.merge('patient_creation_confirmed' => true))
      created_patient = {
        'PROFILE_CODE' => 'patient-created',
        'NAME' => 'Ivan',
        'LASTNAME' => 'Ivanov',
        'MIDDLENAME' => 'Ivanovich',
        'IIN' => '940720300129',
        'PATIENT_PHONE_2' => contact.phone_number
      }
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return([], [], [created_patient])
      allow(client).to receive(:create_patient).and_return('profile_code' => 'patient-created')
      allow(client).to receive(:get_patient).with(patient_code: 'patient-created').and_raise(
        Integrations::Medelement::Client::ApiError.new('not materialized', status: 404)
      )

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-created')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-created')
      expect(client).to have_received(:create_patient).once
    end

    it 'does not retry an ambiguous create result' do
      contact.update!(
        name: 'Ivanov Ivan Ivanovich',
        custom_attributes: { 'medelement_iin' => '940720300129' }
      )
      allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return([])
      allow(client).to receive(:create_patient).and_raise(
        Integrations::Medelement::Client::ApiError.new('ambiguous', ambiguous: true)
      )
      command.update!(execution_state: command.execution_state.merge('patient_creation_confirmed' => true))

      perform

      expect(command.reload).to have_attributes(status: 'reconciliation_required', last_error_code: 'provider_http_error')
      expect(command.execution_state).to include('write_phase' => 'patient_create')
      expect(client).to have_received(:create_patient).once
    end
  end

  context 'when updating a patient' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:operation) { 'update_patient' }
    let(:command_attributes) { { provider_patient_code: 'patient-1' } }

    before do
      allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
        'PROFILE_CODE' => 'patient-1',
        'NAME' => 'Ivan',
        'LASTNAME' => 'Ivanov',
        'PATIENT_PHONE_2' => contact.phone_number
      )
    end

    it 'sends the documented patient payload and marks the command succeeded' do
      allow(client).to receive(:update_patient).and_return({})

      perform

      expect(client).to have_received(:update_patient).once.with(
        params: hash_including('profile_code' => 'patient-1')
      )
      expect(command.reload).to be_succeeded
    end

    it 'uses the confirmed patient payload after the contact changes' do
      confirmed_payload = command.request_snapshot.fetch('patient').fetch('payload')
      contact.update!(name: 'Changed Person')
      allow(client).to receive(:update_patient).and_return({})

      perform

      expect(client).to have_received(:update_patient).once.with(params: confirmed_payload)
    end

    it 'applies the patient code from the exact payload after the command column changes' do
      command.update_column(:provider_patient_code, 'patient-2') # rubocop:disable Rails/SkipsModelValidations
      allow(client).to receive(:update_patient).and_return({})

      perform

      expect(client).to have_received(:update_patient).once.with(params: hash_including('profile_code' => 'patient-1'))
      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
      expect(command.execution_state).to include('write_provider_patient_code' => 'patient-1')
    end

    it 'fails a deterministic provider validation error without reconciliation' do
      allow(client).to receive(:update_patient).and_raise(
        Integrations::Medelement::Client::ApiError.new('invalid', status: 422, ambiguous: false)
      )

      perform

      expect(command.reload).to have_attributes(
        status: 'failed',
        last_error_code: 'provider_http_error',
        last_error_status: 422
      )
      expect(client).to have_received(:update_patient).once
    end

    it 'reconciles an acknowledged update until the requested phone is materialized' do
      allow(client).to receive(:update_patient).and_return({})
      allow(client).to receive(:get_patient).and_return(
        'PROFILE_CODE' => 'patient-1',
        'NAME' => 'Ivan',
        'LASTNAME' => 'Ivanov',
        'PATIENT_PHONE_2' => '+77009999999'
      )

      expect { perform }.to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob).with(command.id)

      expect(command.reload).to have_attributes(
        status: 'reconciliation_required',
        last_error_code: 'patient_update_pending_materialization'
      )
    end

    it 'fences a stale executor after a replacement claims the recovered command' do
      allow(client).to receive(:update_patient)
      allow(executor).to receive(:validate_execution_gate!) do
        command.update_column(:updated_at, 20.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        Integrations::Medelement::ProviderCommandDispatcherJob.perform_now
        replacement = described_class.new(command: command.reload)
        allow(replacement).to receive(:validate_execution_gate!)
        allow(replacement).to receive(:execute_operation!)
        replacement.perform
      end

      perform

      expect(client).not_to have_received(:update_patient)
      expect(command.reload).to have_attributes(status: 'processing', attempt_count: 2, last_error_code: nil)
    end
  end

  context 'when creating a reception' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:appointment) do
      create(:scheduling_appointment, account: account, contact: contact, resource: resource, source: 'manual')
    end
    let(:operation) { 'create_reception' }
    let(:command_attributes) do
      {
        provider_patient_code: 'patient-1',
        company_cabinet_code: 'cabinet-1'
      }
    end

    before do
      allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
        'PROFILE_CODE' => 'patient-1',
        'NAME' => 'Ivan',
        'LASTNAME' => 'Ivanov',
        'PATIENT_PHONE_2' => contact.phone_number
      )
    end

    it 'preflights timetable and collisions, writes once, and applies the canonical external ref' do
      allow_available_destination
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception

      perform

      expect(client).to have_received(:create_reception).once.with(
        params: hash_including(
          patient_code: 'patient-1',
          specialist_code: 'specialist-1',
          company_cabinet_code: 'cabinet-1'
        )
      )
      expect(command.reload).to have_attributes(status: 'succeeded', provider_reception_code: 'reception-1')
      expect(appointment.reload).to have_attributes(source: 'medelement', external_ref: 'medelement:reception:reception-1')
      expect(appointment.custom_attributes).to include('medelement_reception_code' => 'reception-1')
    end

    it 'processes an exact v1 snapshot queued by an old web process' do
      snapshot = command.request_snapshot.deep_dup
      snapshot['version'] = 1
      snapshot.fetch('reception')['nomenclature_code'] = 'legacy-service'
      snapshot.fetch('reception').delete('nomenclature_codes')
      rewrite_confirmed_snapshot!(snapshot)
      allow_available_destination
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception(service_codes: ['legacy-service'])

      perform

      expect(client).to have_received(:create_reception).with(
        params: hash_including(nomenclature_code: ['legacy-service'])
      )
      expect(command.reload).to be_succeeded
    end

    it 'writes the legacy singular service alias for old workers while preserving the full v2 list' do
      primary_service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
      secondary_service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-2' }
      )
      appointment.update!(
        service: primary_service,
        custom_attributes: appointment.custom_attributes.merge('service_ids' => [primary_service.id, secondary_service.id])
      )

      expect(command.request_snapshot.fetch('reception')).to include(
        'nomenclature_code' => 'service-1',
        'nomenclature_codes' => %w[service-1 service-2]
      )
    end

    it 'rejects a mismatched v2 legacy service alias before constructing a provider client' do
      snapshot = command.request_snapshot.deep_dup
      snapshot.fetch('reception')['nomenclature_code'] = 'legacy-service'
      rewrite_confirmed_snapshot!(snapshot)

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'request_snapshot_invalid')
      expect(Integrations::Medelement::Client).not_to have_received(:new)
    end

    it 'uses the linked Contact patient code and does not write it to Appointment metadata' do
      allow_available_destination
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception

      perform

      expect(command.request_snapshot['provider_patient_code']).to eq('patient-1')
      expect(command.request_snapshot).not_to have_key('patient')
      expect(client).to have_received(:create_reception).with(params: hash_including(patient_code: 'patient-1'))
      expect(contact.reload.custom_attributes['medelement_patient_code']).to eq('patient-1')
      expect(appointment.reload.custom_attributes).not_to have_key('medelement_patient_code')
    end

    it 'uses the confirmed reception snapshot after local appointment and resource changes' do
      appointment.update!(client_comment: 'Confirmed details')
      snapshot = command.request_snapshot.fetch('reception')
      confirmed_starts_at = Time.iso8601(snapshot.fetch('destination_starts_at'))
      confirmed_ends_at = Time.iso8601(snapshot.fetch('destination_ends_at'))
      appointment.update!(
        starts_at: confirmed_starts_at + 2.days,
        ends_at: confirmed_ends_at + 2.days,
        client_comment: 'Changed details'
      )
      resource.update!(
        custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-2')
      )
      allow_available_destination(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)

      perform

      expect(client).to have_received(:create_reception).once.with(
        params: hash_including(
          specialist_code: 'specialist-1',
          starttime: confirmed_starts_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M'),
          description: 'Confirmed details'
        )
      )
      expect(appointment.reload).to have_attributes(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)
    end

    it 'uses the snapshot timezone for timetable dates after the hook timezone changes' do
      confirmed_starts_at = Time.iso8601('2026-07-30T20:30:00Z')
      confirmed_ends_at = confirmed_starts_at + 30.minutes
      appointment.update!(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)
      command
      hook.update!(settings: hook.settings.merge('timezone' => 'UTC'))
      allow_available_destination(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)

      perform

      expect(client).to have_received(:timetable).with(
        specialist_code: 'specialist-1',
        starts_on: Date.new(2026, 7, 31),
        ends_on: Date.new(2026, 7, 31)
      )
      expect(client).to have_received(:create_reception).with(
        params: hash_including(starttime: '31.07.2026 01:30')
      )
    end

    it 'applies the patient code that was sent after the command column changes' do
      command.update_column(:provider_patient_code, 'patient-2') # rubocop:disable Rails/SkipsModelValidations
      allow_available_destination
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')
      allow_materialized_reception

      perform

      expect(command.reload.provider_patient_code).to eq('patient-1')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
      expect(appointment.reload.custom_attributes).not_to have_key('medelement_patient_code')
    end

    it 'blocks a write outside the provider working timetable' do
      allow(client).to receive(:timetable).and_return({})
      allow(client).to receive(:get_receptions)
      allow(client).to receive(:create_reception)

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'slot_unavailable')
      expect(client).not_to have_received(:get_receptions)
      expect(client).not_to have_received(:create_reception)
    end

    it 'waits for phone refresh before any reception write when the linked patient phone differs' do
      allow(client).to receive(:get_patient).and_return(
        'PROFILE_CODE' => 'patient-1',
        'PATIENT_PHONE_2' => '+77009999999'
      )
      allow(client).to receive(:timetable)
      allow(client).to receive(:create_reception)

      perform

      expect(command.reload).to have_attributes(
        status: 'awaiting_phone_refresh',
        last_error_code: 'patient_phone_mismatch'
      )
      expect(command.execution_state['patient_action']).to include('refresh_supported' => false)
      expect(client).not_to have_received(:timetable)
      expect(client).not_to have_received(:create_reception)
    end

    it 'keeps the preflight snapshot for an ambiguous create result' do
      allow(client).to receive(:timetable).and_return(timetable_for(appointment.starts_at, appointment.ends_at))
      allow(client).to receive(:get_receptions).and_return(
        [
          {
            'RECEPTION_CODE' => 'existing-1',
            'STARTTIME' => provider_time(appointment.ends_at + 1.hour),
            'ENDTIME' => provider_time(appointment.ends_at + 2.hours),
            'REMOVED' => 0
          }
        ]
      )
      allow(client).to receive(:create_reception).and_raise(
        Integrations::Medelement::Client::ApiError.new('ambiguous', status: 500, ambiguous: true)
      )

      expect { perform }.to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob).with(command.id)

      expect(command.reload).to have_attributes(status: 'reconciliation_required', last_error_code: 'provider_http_error')
      expect(command.execution_state).to include(
        'write_phase' => 'reception_create',
        'preflight_reception_codes' => ['existing-1'],
        'write_provider_patient_code' => 'patient-1'
      )
      expect(client).to have_received(:create_reception).once
    end

    context 'when patient identity is resolved only during execution' do
      let(:contact_custom_attributes) { { 'medelement_iin' => '940720300129' } }

      it 'freezes the resolved patient code before an ambiguous reception write' do
        allow(client).to receive(:search_patients_by_iin).with(iin: '940720300129').and_return(
          [{ 'PROFILE_CODE' => 'patient-1', 'IIN' => '940720300129', 'PATIENT_PHONE_2' => contact.phone_number }]
        )
        allow_available_destination
        allow(client).to receive(:create_reception).and_raise(
          Integrations::Medelement::Client::ApiError.new('ambiguous', status: 500, ambiguous: true)
        )

        expect { perform }.to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob).with(command.id)

        expect(command.reload).to have_attributes(status: 'reconciliation_required', provider_patient_code: 'patient-1')
        expect(command.execution_state).to include(
          'write_phase' => 'reception_create',
          'write_provider_patient_code' => 'patient-1'
        )
      end
    end
  end

  # Move-specific timestamps add one helper above the shared command fixture.
  # rubocop:disable RSpec/MultipleMemoizedHelpers
  context 'when moving a reception' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: { 'medelement_reception_code' => 'reception-1' }
      )
    end
    let(:operation) { 'move_reception' }
    let(:new_starts_at) { appointment.starts_at + 1.day }
    let(:new_ends_at) { appointment.ends_at + 1.day }
    let(:command_attributes) do
      {
        provider_patient_code: 'patient-1',
        provider_reception_code: 'reception-1',
        company_cabinet_code: 'cabinet-1',
        desired_starts_at: new_starts_at,
        desired_ends_at: new_ends_at
      }
    end

    before do
      allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
        'PROFILE_CODE' => 'patient-1',
        'PATIENT_PHONE_2' => contact.phone_number
      )
    end

    it 'verifies current remote state and applies the documented move payload' do
      allow(client).to receive(:get_reception).and_return(
        {
          'PROFILE_CODE' => 'patient-1',
          'SPECIALIST_CODE' => 'specialist-1',
          'STARTTIME' => provider_time(appointment.starts_at),
          'ENDTIME' => provider_time(appointment.ends_at),
          'REMOVED' => 0
        },
        {
          'PROFILE_CODE' => 'patient-1',
          'SPECIALIST_CODE' => 'specialist-1',
          'STARTTIME' => provider_time(new_starts_at),
          'ENDTIME' => provider_time(new_ends_at),
          'REMOVED' => 0
        }
      )
      allow_available_destination(starts_at: new_starts_at, ends_at: new_ends_at)
      allow(client).to receive(:move_reception).and_return({})

      perform

      expect(client).to have_received(:move_reception).once.with(
        params: hash_including(
          patient_code: 'patient-1',
          reception_code: 'reception-1',
          doctor_code: 'specialist-1'
        )
      )
      expect(command.reload).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: new_starts_at, ends_at: new_ends_at)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers

  context 'when removing an already removed reception' do
    let(:appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: { 'medelement_reception_code' => 'reception-1' }
      )
    end
    let(:operation) { 'remove_reception' }
    let(:command_attributes) { { provider_reception_code: 'reception-1' } }

    it 'reconciles local state without repeating the provider remove write' do
      allow(client).to receive(:remove_reception)
      allow(client).to receive(:get_reception).and_return(
        'SPECIALIST_CODE' => 'specialist-1',
        'REMOVED' => 1
      )

      perform

      expect(command.reload).to be_succeeded
      expect(command.request_snapshot).not_to have_key('patient_phone_numbers')
      expect(appointment.reload.status).to eq('cancelled')
      expect(client).not_to have_received(:remove_reception)
    end
  end

  def allow_materialized_reception(starts_at: appointment.starts_at, ends_at: appointment.ends_at, service_codes: [])
    allow(client).to receive(:get_reception).with(reception_code: 'reception-1', version: :v2).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'PROFILE_CODE' => 'patient-1',
      'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => provider_time(starts_at),
      'ENDTIME' => provider_time(ends_at),
      'REMOVED' => 0,
      'SERVICES' => service_codes.map { |code| { 'NOMENCLATURE_CODE' => code } }
    )
  end

  def rewrite_confirmed_snapshot!(snapshot)
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot)
    command.update!(
      execution_state: command.execution_state.merge(
        'request_snapshot' => snapshot,
        'request_fingerprint' => fingerprint
      )
    )
    command.confirmation_request.update!(
      metadata: command.confirmation_request.metadata.merge('request_fingerprint' => fingerprint)
    )
  end

  def allow_available_destination(starts_at: appointment.starts_at, ends_at: appointment.ends_at)
    allow(client).to receive(:timetable).and_return(timetable_for(starts_at, ends_at))
    allow(client).to receive(:get_receptions).and_return([])
  end

  def timetable_for(starts_at, ends_at)
    {
      starts_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y') => {
        'timetable' => [{ 'start' => provider_time(starts_at), 'end' => provider_time(ends_at), 'working' => true }]
      }
    }
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end
end
