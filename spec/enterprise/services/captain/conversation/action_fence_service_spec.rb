require 'rails_helper'

RSpec.describe Captain::Conversation::ActionFenceService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, custom_attributes: {
             'medelement_provider_sync_status' => 'pending'
           })
  end
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, hook: hook,
      operation: 'create_patient', status: 'v2_queued', idempotency_key: SecureRandom.uuid,
      execution_state: { 'request_snapshot' => {
        'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
      } }
    ).tap do |record|
      appointment.update!(custom_attributes: appointment.custom_attributes.merge(
        'medelement_provider_command_id' => record.id
      ))
    end
  end

  it 'stamps Captain provenance without pretending a dispatch-time generation is the original run proof' do
    appointment.update!(conversation: create(:conversation, account: account, contact: contact))
    expect(described_class.origin_for(
             actor_descriptor: { type: 'Captain::Assistant', id: assistant.id }, appointment: appointment
           )).to eq('source' => 'captain_actor', 'assistant_id' => assistant.id,
                    'conversation_id' => appointment.conversation_id)
    expect(described_class.origin_for(actor_descriptor: { type: 'User', id: assistant.id }, appointment: appointment)).to be_nil
  end

  it 'rejects Captain-origin provider receipts before the legacy dispatcher can observe them' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    write_hook = create(:integrations_hook, :medelement, account: account, settings: settings)
    expect do
      Integrations::Medelement::ProviderCommands::CreateService.new(
        account: account, hook: write_hook, contact: contact, operation: 'create_patient',
        idempotency_key: SecureRandom.uuid, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id }
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CAPTAIN_PROVIDER_UNAVAILABLE') }
    expect(Integrations::Medelement::ProviderCommand.where(account: account)).not_to exist
  end

  it 'cancels a queued Captain receipt before provider I/O, projects FAILED, and stays idempotent on replay' do
    expect(Integrations::Medelement::ProviderCommands::Executor).not_to receive(:new)

    2.times { Integrations::Medelement::ProviderCommandJob.perform_now(command.id) }

    expect(command.reload).to have_attributes(status: 'cancelled', last_error_code: described_class::UNAVAILABLE_CODE,
                                              attempt_count: 0)
    expect(appointment.reload.custom_attributes.fetch('medelement_provider_sync_status')).to eq('failed')
  end

  it 'fences the direct executor after claim, even when the job wrapper is bypassed' do
    expect(Integrations::Medelement::Client).not_to receive(:new)

    Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform

    expect(command.reload).to have_attributes(status: 'failed', last_error_code: described_class::UNAVAILABLE_CODE,
                                              attempt_count: 1)
    expect(appointment.reload.custom_attributes.fetch('medelement_provider_sync_status')).to eq('failed')
    expect(command.execution_state).not_to have_key('write_phase')
  end

  it 'never cancels an in-flight or unknown Captain write: read-back remains authoritative' do
    command.update!(status: 'v2_reconciliation_required', execution_state: command.execution_state.merge(
      'write_phase' => 'patient_create'
    ))

    expect(described_class.cancel_pending!(command)).to be(false)
    expect(command.reload).to have_attributes(status: 'v2_reconciliation_required')
    expect(appointment.reload.custom_attributes.fetch('medelement_provider_sync_status')).to eq('pending')
  end

  it 'holds a previously started remote patient write as unknown instead of cancelling or replaying it' do
    command.update!(execution_state: command.execution_state.merge('write_phase' => 'patient_create'))
    expect(Integrations::Medelement::ProviderCommands::Executor).not_to receive(:new)

    Integrations::Medelement::ProviderCommandJob.perform_now(command.id)

    expect(command.reload).to have_attributes(status: 'v2_provider_status_unknown', attempt_count: 0)
    expect(command.execution_state.fetch('write_phase')).to eq('patient_create')
    expect(appointment.reload.custom_attributes.fetch('medelement_provider_sync_status')).to eq('provider_status_unknown')
  end

  it 'never requeues a Captain receipt after reconciling a remote patient already created' do
    command.update!(operation: 'create_reception', company_cabinet_code: 'CAB', status: 'v2_processing',
                    execution_state: command.execution_state.merge('write_phase' => 'patient_create'))

    applier = Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
    applier.patient_resolved_for_reception!(patient_code: 'REMOTE-123')

    expect(command.reload).to have_attributes(status: 'v2_provider_status_unknown', provider_patient_code: 'REMOTE-123')
    expect(appointment.reload.custom_attributes.fetch('medelement_provider_sync_status')).to eq('provider_status_unknown')
  end

  it 'leaves a human-originated legacy command on its existing execution path' do
    actor_id = create(:user, account: account).id
    command.update!(
      status: 'queued', execution_state: { 'request_snapshot' => { 'actor' => { 'type' => 'User', 'id' => actor_id } } }
    )
    executor = instance_double(Integrations::Medelement::ProviderCommands::Executor, perform: true)
    allow(Integrations::Medelement::ProviderCommands::Executor).to receive(:new).and_return(executor)

    Integrations::Medelement::ProviderCommandJob.perform_now(command.id)

    expect(executor).to have_received(:perform).once
    expect(command.reload).to have_attributes(status: 'queued')
  end

  it 'routes v2 command/confirmation/reconciliation to a dedicated queue and legacy jobs to the legacy queue' do
    confirmation = create(:confirmation_request, account: account, contact: contact)
    command.update!(confirmation_request: confirmation)
    jobs = [
      Integrations::Medelement::ProviderCommandJob.new(command.id),
      Integrations::Medelement::ProviderCommandConfirmationJob.new(confirmation.id),
      Integrations::Medelement::ProviderCommandReconciliationJob.new(command.id)
    ]
    expect(jobs.map(&:queue_name)).to eq(['medelement_provider_commands_v2'] * 3)

    command.update!(status: 'queued')
    jobs = [
      Integrations::Medelement::ProviderCommandJob.new(command.id),
      Integrations::Medelement::ProviderCommandConfirmationJob.new(confirmation.id),
      Integrations::Medelement::ProviderCommandReconciliationJob.new(command.id)
    ]
    expect(jobs.map(&:queue_name)).to eq(['medelement_provider_commands'] * 3)
  end
end
