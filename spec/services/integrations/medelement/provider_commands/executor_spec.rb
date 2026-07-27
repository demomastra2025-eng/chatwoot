require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::Executor do
  subject(:perform) { described_class.new(command: command).perform }

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
    Integrations::Medelement::ProviderCommand.create!(
      {
        account: account,
        hook: hook,
        appointment: appointment,
        contact: contact,
        confirmation_request: confirmation_request,
        operation: operation,
        status: 'queued',
        confirmed_at: Time.current,
        idempotency_key: SecureRandom.uuid
      }.merge(command_attributes)
    )
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

  context 'when creating a patient' do
    it 'adopts one exact provider match without issuing a create write' do
      allow(client).to receive(:search_patients_by_phone).and_return([{ 'PROFILE_CODE' => 'patient-1' }])
      allow(client).to receive(:create_patient)

      perform

      expect(command.reload).to have_attributes(status: 'succeeded', provider_patient_code: 'patient-1')
      expect(contact.reload.custom_attributes).to include(
        'medelement_patient_code' => 'patient-1',
        'medelement_patient_match_status' => 'matched'
      )
      expect(client).not_to have_received(:create_patient)
    end

    it 'does not retry an ambiguous create result' do
      allow(client).to receive(:search_patients_by_phone).and_return([])
      allow(client).to receive(:create_patient).and_raise(
        Integrations::Medelement::Client::ApiError.new('ambiguous', ambiguous: true)
      )

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

    it 'sends the documented patient payload and marks the command succeeded' do
      allow(client).to receive(:update_patient).and_return({})

      perform

      expect(client).to have_received(:update_patient).once.with(
        params: hash_including('profile_code' => 'patient-1')
      )
      expect(command.reload).to be_succeeded
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

    it 'preflights timetable and collisions, writes once, and applies the canonical external ref' do
      allow_available_destination
      allow(client).to receive(:create_reception).and_return('RECEPTION_CODE' => 'reception-1')

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

    it 'blocks a write outside the provider working timetable' do
      allow(client).to receive(:timetable).and_return({})
      allow(client).to receive(:get_receptions)
      allow(client).to receive(:create_reception)

      perform

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'slot_unavailable')
      expect(client).not_to have_received(:get_receptions)
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

      perform

      expect(command.reload).to have_attributes(status: 'reconciliation_required', last_error_code: 'provider_http_error')
      expect(command.execution_state).to include(
        'write_phase' => 'reception_create',
        'preflight_reception_codes' => ['existing-1']
      )
      expect(client).to have_received(:create_reception).once
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

    it 'verifies current remote state and applies the documented move payload' do
      allow(client).to receive(:get_reception).and_return(
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'STARTTIME' => provider_time(appointment.starts_at),
        'ENDTIME' => provider_time(appointment.ends_at),
        'REMOVED' => 0
      )
      allow_available_destination(starts_at: new_starts_at, ends_at: new_ends_at)
      allow(client).to receive(:move_reception).and_return({})

      perform

      expect(client).to have_received(:move_reception).once.with(
        params: hash_including(
          paient_code: 'patient-1',
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
      expect(appointment.reload.status).to eq('cancelled')
      expect(client).not_to have_received(:remove_reception)
    end
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
