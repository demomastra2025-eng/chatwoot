require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::ReconciliationService do
  subject(:perform) { described_class.new(command: command).perform }

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Ivanov Ivan',
      phone_number: '+77000000001',
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
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:operation) { 'create_patient' }
  let(:write_phase) { 'patient_create' }
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
      'request_fingerprint' => request_fingerprint
    }
    execution_state = request_execution_state.merge(
      { 'write_phase' => write_phase }.merge(command_attributes.fetch(:execution_state, {}))
    )
    record = Integrations::Medelement::ProviderCommand.create!(
      {
        account: account,
        hook: hook,
        appointment: appointment,
        contact: contact,
        operation: operation,
        status: 'reconciliation_required',
        idempotency_key: SecureRandom.uuid,
        execution_state: execution_state
      }.merge(command_attributes.except(:execution_state))
    )
    confirmation_request = create(
      :confirmation_request,
      account: account,
      status: 'confirmed',
      resolved_at: Time.current,
      metadata: {
        'medelement_provider_command_id' => record.id,
        'operation' => operation,
        'request_fingerprint' => request_fingerprint
      }
    )
    record.update!(
      confirmation_request: confirmation_request,
      execution_state: record.execution_state.merge('confirmation_request_id' => confirmation_request.id)
    )
    record
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
  end

  context 'when the confirmed command identity is no longer valid' do
    it 'does not construct a provider client after confirmation metadata changes' do
      command.confirmation_request.update!(metadata: command.confirmation_request.metadata.merge('operation' => 'remove_reception'))

      perform

      expect(Integrations::Medelement::Client).not_to have_received(:new)
      expect(command.reload).to have_attributes(
        status: 'failed',
        last_error_code: 'reconciliation_invalid_confirmation'
      )
    end

    it 'does not construct a provider client after the request snapshot changes' do
      mutated_state = command.execution_state.deep_dup
      mutated_state['request_snapshot']['operation'] = 'update_patient'
      command.update_column(:execution_state, mutated_state) # rubocop:disable Rails/SkipsModelValidations

      perform

      expect(Integrations::Medelement::Client).not_to have_received(:new)
      expect(command.reload).to have_attributes(
        status: 'failed',
        last_error_code: 'reconciliation_invalid_request_snapshot'
      )
    end
  end

  context 'when patient creation returned an ambiguous result' do
    it 'adopts one exact match without repeating the create write' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }]
      )
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
      expect(client).not_to have_received(:create_patient)
    end

    it 'rejects manual cancellation while the reconciliation claim is in flight' do
      actor = create(:user, :administrator, account: account)
      command.update!(execution_state: command.execution_state.merge('execution_started_at' => 1.hour.ago.iso8601))
      allow(client).to receive(:search_patients_by_phone) do
        expect(Time.iso8601(command.reload.execution_state.fetch('execution_started_at'))).to be > 1.minute.ago
        expect do
          Integrations::Medelement::ProviderCommands::CancelService.new(command: command, actor: actor).perform
        end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_NOT_CANCELLABLE') }
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }]
      end

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
    end

    it 'does not mutate local patient state after losing the reconciliation claim' do
      allow(client).to receive(:search_patients_by_phone) do
        state = command.reload.execution_state.except(
          Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIM_TOKEN_KEY,
          Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIMED_AT_KEY
        )
        command.update!(status: 'reconciliation_required', execution_state: state)
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }]
      end

      perform

      expect(command.reload).to be_reconciliation_required
      expect(command.provider_patient_code).to be_blank
      expect(contact.reload.custom_attributes['medelement_patient_code']).to be_blank
    end

    it 'schedules a bounded retry when no exact match exists' do
      allow(client).to receive(:search_patients_by_phone).and_return([])

      perform

      expect(command.reload).to be_reconciliation_required
      expect(command.reconciliation_attempts).to eq(1)
      expect(command.reconciliation_next_at).to be > Time.current
      expect(command.last_error_code).to eq('reconciliation_no_match')
    end

    it 'fails deterministically when provider data belongs to another organization' do
      allow(client).to receive(:search_patients_by_phone)
        .and_raise(Integrations::Medelement::ProviderScope::MismatchError)

      perform

      expect(command.reload).to have_attributes(
        status: 'failed',
        last_error_code: 'provider_scope_mismatch'
      )
    end

    it 'does not consume another attempt when a duplicate job runs before the backoff is due' do
      expect(client).to receive(:search_patients_by_phone).once.and_return([])

      perform
      first_next_at = command.reload.reconciliation_next_at
      perform

      expect(command.reload).to be_reconciliation_required
      expect(command.reconciliation_attempts).to eq(1)
      expect(command.reconciliation_next_at).to eq(first_next_at)
    end

    it 'fails terminally after the final unresolved attempt' do
      command.update!(
        execution_state: command.execution_state.merge(
          'reconciliation_attempts' => Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS - 1
        )
      )
      allow(client).to receive(:search_patients_by_phone).and_return([])

      perform

      expect(command.reload).to have_attributes(
        status: 'failed',
        last_error_code: 'reconciliation_exhausted'
      )
      expect(command.reconciliation_attempts).to eq(
        Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      )
    end
  end

  context 'when patient creation was ambiguous inside reception creation' do
    let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
    let(:operation) { 'create_reception' }
    let(:command_attributes) { { company_cabinet_code: 'cabinet-1' } }

    it 'requeues with the patient identity already linked to the Contact' do
      contact.update!(custom_attributes: { 'medelement_patient_code' => 'patient-old' })
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov' }]
      )
      allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)

      perform

      expect(command.reload).to have_attributes(status: 'queued', provider_patient_code: 'patient-old')
      expect(contact.reload.custom_attributes['medelement_patient_code']).to eq('patient-old')
      expect(client).not_to have_received(:search_patients_by_phone)
      expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(command.id)
    end
  end

  context 'when patient update returned an ambiguous result' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:operation) { 'update_patient' }
    let(:command_attributes) do
      {
        provider_patient_code: 'patient-1',
        execution_state: { 'write_phase' => 'patient_update' }
      }
    end

    it 'accepts an exact remote patient snapshot without repeating the update write' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [
          {
            'PROFILE_CODE' => 'patient-1',
            'NAME' => 'Ivan',
            'LASTNAME' => 'Ivanov',
            'MIDDLENAME' => '',
            'PATIENT_PHONE_2' => contact.phone_number,
            'REMOVED' => 0
          }
        ]
      )

      perform

      expect(command.reload).to be_succeeded
    end

    it 'keeps reconciliation pending when the remote snapshot differs' do
      allow(client).to receive(:search_patients_by_phone).and_return(
        [{ 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Other', 'LASTNAME' => 'Ivanov', 'REMOVED' => 0 }]
      )

      perform

      expect(command.reload).to be_reconciliation_required
    end
  end

  context 'when reception creation returned an ambiguous result' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
    let(:operation) { 'create_reception' }
    let(:write_phase) { 'reception_create' }
    let(:command_attributes) do
      {
        provider_patient_code: 'patient-1',
        company_cabinet_code: 'cabinet-1',
        execution_state: {
          'write_phase' => 'reception_create',
          'write_provider_patient_code' => 'patient-1',
          'preflight_reception_codes' => ['existing-1']
        }
      }
    end

    it 'adopts the exact reception returned by the write before falling back to timetable search' do
      command.update!(
        provider_reception_code: 'created-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'created-1')
      )
      allow(client).to receive(:get_reception)
        .with(reception_code: 'created-1', version: :v2)
        .and_return(reception('created-1'))
      allow(client).to receive(:get_receptions)

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_reception_code: 'created-1')
      expect(appointment.reload.external_ref).to eq('medelement:reception:created-1')
      expect(client).not_to have_received(:get_receptions)
    end

    it 'does not adopt the exact returned reception when its confirmed service row is soft-deleted' do
      service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge('service_ids' => [service.id])
      )
      command.update!(
        provider_reception_code: 'created-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'created-1')
      )
      allow(client).to receive(:get_reception)
        .with(reception_code: 'created-1', version: :v2)
        .and_return(
          reception('created-1').merge(
            'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1', 'DELETED' => true }]
          )
        )
      allow(client).to receive(:get_receptions).and_return([])

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'does not adopt the returned reception when it contains an unconfirmed extra service' do
      service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge('service_ids' => [service.id])
      )
      command.update!(
        provider_reception_code: 'created-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'created-1')
      )
      allow(client).to receive(:get_reception)
        .with(reception_code: 'created-1', version: :v2)
        .and_return(
          reception('created-1').merge(
            'SERVICES' => [
              { 'NOMENCLATURE_CODE' => 'service-1' },
              { 'NOMENCLATURE_CODE' => 'unexpected-service' }
            ]
          )
        )
      allow(client).to receive(:get_receptions).and_return([])

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'does not adopt the exact returned reception from another cabinet' do
      command.update!(
        provider_reception_code: 'created-1',
        execution_state: command.execution_state.merge('write_provider_reception_code' => 'created-1')
      )
      allow(client).to receive(:get_reception)
        .with(reception_code: 'created-1', version: :v2)
        .and_return(reception('created-1').merge('COMPANY_CABINET_CODE' => 'other-cabinet'))
      allow(client).to receive(:get_receptions).and_return([])

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'adopts exactly one new matching reception that was absent from preflight' do
      allow(client).to receive(:get_receptions).and_return(
        [
          reception('existing-1'),
          reception('created-1')

        ]
      )

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_reception_code: 'created-1')
      expect(appointment.reload.external_ref).to eq('medelement:reception:created-1')
    end

    it 'applies the patient code from the matched remote reception after the command column changes' do
      command.update_column(:provider_patient_code, 'patient-2') # rubocop:disable Rails/SkipsModelValidations
      allow(client).to receive(:get_receptions).and_return([reception('created-1')])

      perform

      expect(command.reload.provider_patient_code).to eq('patient-1')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
      expect(appointment.reload.custom_attributes).not_to have_key('medelement_patient_code')
    end

    context 'when the patient was resolved only during execution' do
      let(:contact_custom_attributes) { {} }
      let(:command_attributes) do
        {
          provider_patient_code: 'patient-2',
          company_cabinet_code: 'cabinet-1',
          execution_state: {
            'write_phase' => 'reception_create',
            'write_provider_patient_code' => 'patient-1',
            'preflight_reception_codes' => ['existing-1']
          }
        }
      end

      it 'matches with the patient code frozen immediately before the write' do
        allow(client).to receive(:get_receptions).and_return([reception('created-1')])

        perform

        expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
        expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
        expect(appointment.reload.custom_attributes).not_to have_key('medelement_patient_code')
      end
    end

    it 'keeps manual reconciliation when more than one new reception matches' do
      allow(client).to receive(:get_receptions).and_return(
        [
          reception('created-1'),
          reception('created-2')
        ]
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'keeps reconciliation pending when the only matching reception is removed' do
      allow(client).to receive(:get_receptions).and_return(
        [reception('created-1').merge('REMOVED' => 1)]
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'keeps reconciliation pending when the provider reception omits a confirmed service' do
      service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge('service_ids' => [service.id])
      )
      allow(client).to receive(:get_receptions).and_return([reception('created-1').merge('SERVICES' => [])])

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end

    it 'keeps reconciliation pending when the confirmed service row is soft-deleted' do
      service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge('service_ids' => [service.id])
      )
      allow(client).to receive(:get_receptions).and_return(
        [
          reception('created-1').merge(
            'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1', 'DELETED' => 1 }]
          )
        ]
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.external_ref).to be_blank
    end
  end

  context 'when reception move returned an ambiguous result' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:reception-1'
      )
    end
    let(:operation) { 'move_reception' }
    let(:write_phase) { 'reception_move' }
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

    it 'applies local move only when remote state equals the desired state' do
      allow(client).to receive(:get_reception).and_return(
        'RECEPTION_CODE' => 'reception-1',
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'COMPANY_CABINET_CODE' => 'cabinet-1',
        'REMOVED' => 0,
        'STARTTIME' => provider_time(new_starts_at),
        'ENDTIME' => provider_time(new_ends_at)
      )

      perform

      expect(command.reload).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: new_starts_at, ends_at: new_ends_at)
    end

    it 'keeps reconciliation pending when move readback contains an unconfirmed service' do
      allow(client).to receive(:get_reception).and_return(
        'RECEPTION_CODE' => 'reception-1',
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'COMPANY_CABINET_CODE' => 'cabinet-1',
        'REMOVED' => 0,
        'STARTTIME' => provider_time(new_starts_at),
        'ENDTIME' => provider_time(new_ends_at),
        'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'unexpected-service' }]
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.starts_at).not_to eq(new_starts_at)
    end

    it 'reconciles against the confirmed snapshot after local and command timestamps change' do
      snapshot = command.request_snapshot.fetch('reception')
      confirmed_starts_at = Time.iso8601(snapshot.fetch('destination_starts_at'))
      confirmed_ends_at = Time.iso8601(snapshot.fetch('destination_ends_at'))
      command.update_columns( # rubocop:disable Rails/SkipsModelValidations
        desired_starts_at: confirmed_starts_at + 2.days,
        desired_ends_at: confirmed_ends_at + 2.days
      )
      appointment.update_columns( # rubocop:disable Rails/SkipsModelValidations
        starts_at: confirmed_starts_at + 3.days,
        ends_at: confirmed_ends_at + 3.days
      )
      allow(client).to receive(:get_reception).and_return(
        'RECEPTION_CODE' => 'reception-1',
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'COMPANY_CABINET_CODE' => 'cabinet-1',
        'REMOVED' => 0,
        'STARTTIME' => provider_time(confirmed_starts_at),
        'ENDTIME' => provider_time(confirmed_ends_at)
      )

      perform

      expect(command.reload).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: confirmed_starts_at, ends_at: confirmed_ends_at)
    end

    it 'keeps reconciliation pending when remote identity no longer matches' do
      allow(client).to receive(:get_reception).and_return(
        'RECEPTION_CODE' => 'reception-1',
        'PROFILE_CODE' => 'other-patient',
        'SPECIALIST_CODE' => 'specialist-1',
        'COMPANY_CABINET_CODE' => 'cabinet-1',
        'REMOVED' => 0,
        'STARTTIME' => provider_time(new_starts_at),
        'ENDTIME' => provider_time(new_ends_at)
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.starts_at).not_to eq(new_starts_at)
    end

    it 'keeps reconciliation pending when the provider response omits identity fields' do
      allow(client).to receive(:get_reception).and_return(
        'STARTTIME' => provider_time(new_starts_at),
        'ENDTIME' => provider_time(new_ends_at)
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.starts_at).not_to eq(new_starts_at)
    end
  end

  context 'when reception removal returned an ambiguous result' do
    let(:contact_custom_attributes) { { 'medelement_patient_code' => 'patient-1' } }
    let(:appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }
      )
    end
    let(:operation) { 'remove_reception' }
    let(:write_phase) { 'reception_remove' }
    let(:command_attributes) do
      { provider_patient_code: 'patient-1', provider_reception_code: 'reception-1', company_cabinet_code: 'cabinet-1' }
    end

    it 'applies local cancellation only after remote removal is visible' do
      allow(client).to receive(:get_reception).and_return(reception('reception-1').merge('REMOVED' => 1))

      perform

      expect(command.reload).to be_succeeded
      expect(appointment.reload.status).to eq('cancelled')
    end

    it 'keeps reconciliation pending when the removed reception identity differs' do
      allow(client).to receive(:get_reception).and_return(
        reception('reception-1').merge('REMOVED' => 1, 'PATIENT_CODE' => 'other-patient')
      )

      perform

      expect(command.reload).to be_reconciliation_required
      expect(appointment.reload.status).not_to eq('cancelled')
    end
  end

  def reception(code)
    {
      'RECEPTION_CODE' => code,
      'PATIENT_CODE' => 'patient-1',
      'SPECIALIST_CODE' => 'specialist-1',
      'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => provider_time(appointment.starts_at),
      'ENDTIME' => provider_time(appointment.ends_at),
      'REMOVED' => 0,
      'SERVICES' => []
    }
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end
end
