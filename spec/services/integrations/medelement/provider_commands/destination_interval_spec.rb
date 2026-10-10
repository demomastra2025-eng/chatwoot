require 'rails_helper'

RSpec.describe 'Medelement reception destination intervals' do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.utc(2026, 4, 19, 20)) do
      Outbound::PlaygroundDeliveryPolicy.with(nil) { example.run }
    end
  end

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:user) { create(:user, account: account) }
  let(:contact) do
    create(:contact, account: account, name: 'Test', last_name: 'Patient', phone_number: '+77000000001',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:resource) do
    create(:scheduling_resource, account: account, custom_attributes: {
      'medelement_specialist_code' => 'doctor-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
    })
  end
  let(:starts_at) { Time.zone.local(2026, 4, 20, 10) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: source,
                                    starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30,
                                    client_first_name: 'Test', client_last_name: 'Patient',
                                    custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' },
                                    external_ref: source == 'medelement' ? 'medelement:reception:reception-1' : nil)
  end
  let(:source) { 'medelement' }
  let(:hook) do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
  end
  let(:operation) { 'move_reception' }
  let(:command) do
    Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: hook, appointment: appointment, actor: user, operation: operation,
      company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid,
      desired_starts_at: starts_at + 1.day, desired_ends_at: starts_at + 1.day + 30.minutes
    ).perform
  end

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
  end

  def queue_legacy_interval(seconds, write_phase: nil)
    snapshot = command.request_snapshot.deep_dup
    destination_end = Time.iso8601(snapshot.fetch('reception').fetch('destination_starts_at')) + seconds
    snapshot['reception']['destination_ends_at'] = destination_end.iso8601(6)
    snapshot['desired_ends_at'] = destination_end.iso8601(6)
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot)
    state = command.execution_state.merge('request_snapshot' => snapshot, 'request_fingerprint' => fingerprint)
    state['write_phase'] = write_phase if write_phase
    command.confirmation_request.update!(
      status: 'confirmed', resolved_at: Time.current,
      metadata: command.confirmation_request.metadata.merge('request_fingerprint' => fingerprint)
    )
    # Historical commands must bypass the new staging validation to exercise claim/error transitions.
    command.update_columns(desired_ends_at: destination_end, execution_state: state, status: 'v2_queued') # rubocop:disable Rails/SkipsModelValidations
    command.reload
  end

  shared_examples 'a rejected queued destination' do
    [60, 1441 * 60, 330, 300.1].each do |seconds|
      it "rejects #{seconds} seconds before constructing the provider client" do
        queue_legacy_interval(seconds)
        expect(Integrations::Medelement::Client).not_to receive(:new)

        expect { Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform }
          .not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)

        expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'INVALID_DURATION', attempt_count: 1)
        expect(command.execution_state['write_phase']).to be_nil
        expect(appointment.reload).to have_attributes(starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30)
      end
    end
  end

  include_examples 'a rejected queued destination'

  context 'when the queued command creates a reception' do
    let(:operation) { 'create_reception' }
    let(:source) { 'manual' }

    include_examples 'a rejected queued destination'
  end

  it 'retains an unsupported destination that may already have been written for reconciliation' do
    queue_legacy_interval(60, write_phase: 'reception_move')
    expect(Integrations::Medelement::Client).not_to receive(:new)

    expect { Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform }
      .to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob).with(command.id)

    expect(command.reload).to be_reconciliation_required
    expect(command).to have_attributes(last_error_code: 'INVALID_DURATION', attempt_count: 1)
    expect(command.execution_state['write_phase']).to eq('reception_move')
    Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command).perform
    expect(command.reload).to be_provider_status_unknown
    expect(command.last_error_code).to eq('provider_status_unknown')
    expect(command.execution_state).to include(
      'provider_status_unknown_reason' => 'reconciliation_invalid_request_snapshot',
      'write_phase' => 'reception_move'
    )
    expect(appointment.reload).to have_attributes(starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30)
  end

  it 'checks an unsupported captured interval before preflight reads remote state' do
    queue_legacy_interval(60)
    client = instance_double(Integrations::Medelement::Client)
    expect(client).not_to receive(:get_reception)
    expect(client).not_to receive(:timetable)
    expect(client).not_to receive(:get_receptions)
    preflight = Integrations::Medelement::ProviderCommands::Preflight.new(command: command, client: client, configuration: nil)

    expect { preflight.perform }.to raise_error do |error|
      expect(error.class.name).to eq('Integrations::Medelement::ProviderCommands::RequestSnapshotSchema::DestinationIntervalError')
      expect(error.code).to eq('INVALID_DURATION')
    end
  end

  context 'when a supported creation interval is fully covered by the provider timetable' do
    let(:operation) { 'create_reception' }
    let(:source) { 'manual' }

    [5, 1440].each do |minutes|
      it "allows exactly #{minutes} minutes through queued execution and confirmed projection" do
        queue_legacy_interval(minutes * 60)
        destination_start = Time.iso8601(command.request_snapshot.fetch('reception').fetch('destination_starts_at'))
        destination_end = destination_start + minutes.minutes
        appointment.update!(starts_at: destination_start, ends_at: destination_end)
        client = instance_double(Integrations::Medelement::Client)
        allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
          'PROFILE_CODE' => 'patient-1', 'PATIENT_PHONE_2' => contact.phone_number
        )
        allow(client).to receive(:timetable).and_return(
          destination_start.to_date.to_s => { 'timetable' => [
            { 'start' => provider_time(destination_start), 'end' => provider_time(destination_end), 'working' => true }
          ] }
        )
        allow(client).to receive(:get_receptions).and_return([])
        allow(client).to receive(:create_reception).and_return('reception_code' => 'reception-2')
        allow(client).to receive(:get_reception).and_return(
          'RECEPTION_CODE' => 'reception-2', 'PROFILE_CODE' => 'patient-1', 'SPECIALIST_CODE' => 'doctor-1',
          'COMPANY_CABINET_CODE' => 'cabinet-1', 'STARTTIME' => provider_time(destination_start),
          'ENDTIME' => provider_time(destination_end), 'REMOVED' => 0, 'SERVICE_CODES' => []
        )

        Integrations::Medelement::ProviderCommands::Executor.new(command: command, client: client).perform

        expect(client).to have_received(:create_reception).once
        expect(command.reload).to be_succeeded
        expect(appointment.reload).to have_attributes(starts_at: destination_start, ends_at: destination_end, duration_min: minutes)
      end
    end
  end

  it 'leaves odd imported source intervals outside the destination rule for removal' do
    appointment.update!(ends_at: starts_at + 1.minute)
    removal = Integrations::Medelement::ProviderCommand.new(
      account: account, hook: hook, contact: contact, appointment: appointment, operation: 'remove_reception',
      status: 'awaiting_confirmation', idempotency_key: SecureRandom.uuid
    )
    snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, contact: contact, appointment: appointment, operation: 'remove_reception',
      company_cabinet_code: 'cabinet-1'
    ).build

    expect(removal).to be_valid
    expect(Integrations::Medelement::ProviderCommands::RequestSnapshotSchema.valid?(snapshot)).to be(true)
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end
end
