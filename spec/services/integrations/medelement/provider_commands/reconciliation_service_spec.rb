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
      expect(command.reload).to be_reconciliation_required
    end

    it 'does not construct a provider client after the request snapshot changes' do
      mutated_state = command.execution_state.deep_dup
      mutated_state['request_snapshot']['operation'] = 'update_patient'
      command.update_column(:execution_state, mutated_state) # rubocop:disable Rails/SkipsModelValidations

      perform

      expect(Integrations::Medelement::Client).not_to have_received(:new)
      expect(command.reload).to be_reconciliation_required
    end
  end

  context 'when patient creation returned an ambiguous result' do
    it 'adopts one exact match without repeating the create write' do
      allow(client).to receive(:search_patients_by_phone).and_return([{ 'PROFILE_CODE' => 'patient-1' }])
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
      expect(contact.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
      expect(client).not_to have_received(:create_patient)
    end

    it 'keeps manual reconciliation when no exact match exists' do
      allow(client).to receive(:search_patients_by_phone).and_return([])

      perform

      expect(command.reload).to be_reconciliation_required
    end
  end

  context 'when patient creation was ambiguous inside reception creation' do
    let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
    let(:operation) { 'create_reception' }
    let(:command_attributes) { { company_cabinet_code: 'cabinet-1' } }

    it 'links the patient and requeues the already confirmed composite command' do
      allow(client).to receive(:search_patients_by_phone).and_return([{ 'PROFILE_CODE' => 'patient-1' }])
      allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)

      perform

      expect(command.reload).to have_attributes(status: 'queued', provider_patient_code: 'patient-1')
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
          'preflight_reception_codes' => ['existing-1']
        }
      }
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
      expect(appointment.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
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
        expect(appointment.reload.custom_attributes).to include('medelement_patient_code' => 'patient-1')
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
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'REMOVED' => 0,
        'STARTTIME' => provider_time(new_starts_at),
        'ENDTIME' => provider_time(new_ends_at)
      )

      perform

      expect(command.reload).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: new_starts_at, ends_at: new_ends_at)
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
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
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
        'PROFILE_CODE' => 'other-patient',
        'SPECIALIST_CODE' => 'specialist-1',
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
    let(:operation) { 'remove_reception' }
    let(:write_phase) { 'reception_remove' }
    let(:command_attributes) { { provider_reception_code: 'reception-1' } }

    it 'applies local cancellation only after remote removal is visible' do
      allow(client).to receive(:get_reception).and_return('REMOVED' => 1)

      perform

      expect(command.reload).to be_succeeded
      expect(appointment.reload.status).to eq('cancelled')
    end
  end

  def reception(code)
    {
      'RECEPTION_CODE' => code,
      'PATIENT_CODE' => 'patient-1',
      'STARTTIME' => provider_time(appointment.starts_at),
      'ENDTIME' => provider_time(appointment.ends_at),
      'REMOVED' => 0
    }
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end
end
