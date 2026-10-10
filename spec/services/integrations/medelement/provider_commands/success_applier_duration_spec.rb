require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::SuccessApplier do
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
  let(:source) { 'medelement' }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: source,
                                    starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30,
                                    client_first_name: 'Test', client_last_name: 'Patient',
                                    external_ref: source == 'medelement' ? 'medelement:reception:reception-1' : nil,
                                    custom_attributes: {
                                      'medelement_cabinet_code' => 'cabinet-1',
                                      **(source == 'medelement' ? { 'medelement_reception_code' => 'reception-1' } : {})
                                    })
  end
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    hook
    appointment.reload
    user
    expect(Integrations::Medelement::Client).not_to receive(:new)
  end

  def stage_command(operation:, destination_start:, destination_end:)
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: hook, appointment: appointment, actor: user, operation: operation,
      company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid,
      desired_starts_at: destination_start, desired_ends_at: destination_end
    ).perform
    if source == 'medelement'
      command.update!(execution_state: command.execution_state.merge(
        Scheduling::Appointments::ImportedProviderMutationService::SOURCE_SNAPSHOT_KEY =>
          Scheduling::Appointments::ImportedProviderMutationService.source_snapshot(appointment)
      ))
    end
    command.update!(status: command.status_for_transition('processing'))
    command
  end

  [30, 75].each do |duration|
    it "projects the confirmed imported move interval of #{duration} minutes instead of retaining its old duration" do
      destination_start = starts_at + 1.hour
      destination_end = destination_start + duration.minutes
      command = stage_command(operation: 'move_reception', destination_start: destination_start, destination_end: destination_end)
      expect(appointment.reload.duration_min).to eq(30)

      expect(described_class.new(command: command).reception_moved!).to be(true)

      expect(appointment.reload).to have_attributes(starts_at: destination_start, ends_at: destination_end, duration_min: duration,
                                                   source: 'medelement', contact_id: contact.id,
                                                   external_ref: 'medelement:reception:reception-1')
      expect(command.reload).to be_succeeded
      expect(Scheduling::PayloadBuilder.appointment(appointment)[:duration_min]).to eq(duration)
    end
  end

  context 'when a new confirmed reception has an existing local duration' do
    let(:source) { 'manual' }

    [30, 75].each do |duration|
      it "projects the exact confirmed creation interval of #{duration} minutes" do
        destination_end = starts_at + duration.minutes
        appointment.update!(ends_at: destination_end)
        command = stage_command(operation: 'create_reception', destination_start: starts_at, destination_end: destination_end)
        expect(appointment.reload.duration_min).to eq(30)

        expect(described_class.new(command: command).reception_created!(reception_code: 'reception-2', patient_code: 'patient-1')).to be(true)

        expect(appointment.reload).to have_attributes(starts_at: starts_at, ends_at: destination_end, duration_min: duration,
                                                     source: 'manual', contact_id: contact.id,
                                                     external_ref: 'medelement:reception:reception-2')
        expect(command.reload).to be_succeeded
      end
    end
  end

  it 'frees a locally cancelled reception only after the exact remove command succeeds' do
    hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
    appointment.mark_medelement_provider_reconciled!
    appointment.update!(status: 'cancelled', custom_attributes: appointment.custom_attributes.merge(
      Integrations::Medelement::LocalCancellation::MARKER_KEY => true
    ))
    expect(Integrations::Medelement::LocalCancellation.provider_occupied?(appointment)).to be(true)
    command = stage_command(operation: 'remove_reception', destination_start: nil, destination_end: nil)
    expect(Scheduling::Appointments::ImportedProviderMutationService.current_source?(command)).to be(true)

    expect(described_class.new(command: command).reception_removed!).to be(true)

    expect(appointment.reload.custom_attributes).not_to have_key(Integrations::Medelement::LocalCancellation::MARKER_KEY)
    expect(Integrations::Medelement::LocalCancellation.provider_occupied?(appointment)).to be(false)
    expect(Integrations::Medelement::AppointmentProviderStatus.payload(appointment)).to include(
      provider_confirmed: true, provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'medelement'
    )
  end
end
