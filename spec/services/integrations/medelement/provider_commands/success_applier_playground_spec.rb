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
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: 'medelement',
                                    client_first_name: 'Test', client_last_name: 'Patient',
                                    external_ref: 'medelement:reception:reception-1', custom_attributes: {
                                      'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1'
                                    })
  end
  let(:hook_settings) do
    attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true, 'remove_reception_on_cancel' => true)
  end
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }
  let(:policy) do
    Outbound::PlaygroundDeliveryPolicy.issue(
      'mode' => 'live', 'run_id' => SecureRandom.uuid, 'session_id' => SecureRandom.uuid,
      'account_id' => account.id, 'user_id' => user.id, 'caller_contact_id' => contact.id, 'delivery_enabled' => false
    )
  end

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    hook
    appointment.reload
    user
  end

  def stage_command(operation: 'move_reception', run_policy: policy)
    command = Outbound::PlaygroundDeliveryPolicy.with(run_policy) do
      Integrations::Medelement::ProviderCommands::CreateService.new(
        account: account, hook: hook, appointment: appointment, actor: user, operation: operation,
        company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid,
        desired_starts_at: appointment.starts_at + 1.hour, desired_ends_at: appointment.ends_at + 1.hour
      ).perform
    end
    command.update!(status: command.status_for_transition('processing'))
    command
  end

  it 'captures the signed run on the ordinary command boundary and preserves it when a later worker applies the move' do
    expect(Integrations::Medelement::Client).not_to receive(:new)
    command = stage_command

    expect(command.execution_state['captain_playground']).to eq(policy)
    expect(Current.playground_run_policy).to be_nil
    expect(described_class.new(command: command).reception_moved!).to be(true)

    expect(appointment.reload.custom_attributes['captain_playground']).to eq(policy)
    expect(Outbound::PlaygroundDeliveryPolicy.verified(appointment.custom_attributes['captain_playground']))
      .to include(delivery_enabled: false)
    expect(Current.playground_run_policy).to be_nil
  end

  it 'keeps the original queued run even when an ordinary later mutation cleared the appointment stamp' do
    command = stage_command
    appointment.update!(custom_attributes: appointment.custom_attributes.except('captain_playground'))

    described_class.new(command: command).reception_moved!

    expect(appointment.reload.custom_attributes['captain_playground']).to eq(policy)
    expect(command.reload.execution_state['captain_playground']).to eq(policy)
  end

  it 'clears a stale appointment run on the next ordinary command with no inherited run' do
    first = stage_command
    described_class.new(command: first).reception_moved!
    appointment.reload

    ordinary = stage_command(run_policy: nil)
    described_class.new(command: ordinary).reception_moved!

    expect(ordinary.execution_state).not_to have_key('captain_playground')
    expect(appointment.reload.custom_attributes).not_to have_key('captain_playground')
    expect(first.reload.execution_state['captain_playground']).to eq(policy)
  end

  it 'preserves the queued signed policy when applying a confirmed removal' do
    command = stage_command(operation: 'remove_reception')

    described_class.new(command: command).reception_removed!

    expect(appointment.reload).to have_attributes(status: 'cancelled', source: 'medelement', contact_id: contact.id)
    expect(appointment.custom_attributes['captain_playground']).to eq(policy)
    expect(command.reload).to be_succeeded
    expect(Current.playground_run_policy).to be_nil
  end

  [{}, false, { 'token' => 'invalid' }].each do |invalid|
    it "keeps invalid run metadata #{invalid.inspect} as taint through command creation and readback" do
      command = stage_command(run_policy: invalid)

      described_class.new(command: command).reception_moved!

      expect(command.execution_state['captain_playground']).to eq(invalid)
      expect(appointment.reload.custom_attributes['captain_playground']).to eq(invalid)
      expect(Outbound::PlaygroundDeliveryPolicy.verified(appointment.custom_attributes['captain_playground'])).to be_nil
    end
  end

  it 'keeps an expired signed run as taint instead of converting it into ordinary delivery' do
    command = stage_command
    travel 25.hours

    described_class.new(command: command).reception_moved!

    expect(appointment.reload.custom_attributes['captain_playground']).to eq(policy)
    expect(Outbound::PlaygroundDeliveryPolicy.verified(appointment.custom_attributes['captain_playground'])).to be_nil
  end

  it 'does not replace invalid inherited context with the otherwise valid queued signature' do
    command = stage_command

    Outbound::PlaygroundDeliveryPolicy.with({}) do
      described_class.new(command: command).reception_moved!
      expect(Current.playground_run_policy).to eq({})
    end

    expect(appointment.reload.custom_attributes['captain_playground']).to eq({})
    expect(command.reload.execution_state['captain_playground']).to eq(policy)
    expect(Current.playground_run_policy).to be_nil
  end

  it 'refuses stale imported readback and preserves a later local mutation' do
    command = stage_command(run_policy: nil)
    command.update!(execution_state: command.execution_state.merge(
      Scheduling::Appointments::ImportedProviderMutationService::SOURCE_SNAPSHOT_KEY =>
        Scheduling::Appointments::ImportedProviderMutationService.source_snapshot(appointment)
    ))
    original_starts_at = appointment.starts_at
    appointment.update!(client_comment: 'A later authorized edit')

    expect { described_class.new(command: command).reception_moved! }.to raise_error do |error|
      expect(error.class.name).to eq('Scheduling::Error')
      expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL')
    end

    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, client_comment: 'A later authorized edit')
    expect(appointment.custom_attributes).not_to have_key('medelement_provider_sync_status')
    expect(command.reload).to be_processing
  end
end
