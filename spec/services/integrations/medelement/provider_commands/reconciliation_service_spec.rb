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
    Integrations::Medelement::ProviderCommand.create!(
      {
        account: account,
        hook: hook,
        appointment: appointment,
        contact: contact,
        operation: operation,
        status: 'reconciliation_required',
        idempotency_key: SecureRandom.uuid,
        execution_state: { 'write_phase' => write_phase }
      }.merge(command_attributes)
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
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
