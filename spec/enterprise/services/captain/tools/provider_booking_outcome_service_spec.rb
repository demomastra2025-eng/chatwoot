require 'rails_helper'

RSpec.describe Captain::Tools::ProviderBookingOutcomeService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, resource: resource) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', status: 'processing', idempotency_key: 'booking-result-1',
      company_cabinet_code: 'cabinet-1', provider_patient_code: 'patient-1',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      execution_state: {
        'request_fingerprint' => 'fingerprint-1', 'dispatch_identity' => 'dispatch-1',
        'request_snapshot' => {
          'version' => Integrations::Medelement::ProviderCommands::RequestSnapshotSchema::VERSION,
          'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
          'company_cabinet_code' => 'cabinet-1',
          'conversation_id' => conversation.id,
          'reception' => {
            'resource_id' => resource.id,
            'destination_starts_at' => appointment.starts_at.iso8601,
            'destination_ends_at' => appointment.ends_at.iso8601,
            'nomenclature_codes' => []
          }
        }
      }
    )
  end
  let(:service) { described_class.new(appointment: appointment, assistant: assistant) }

  before do
    appointment.update!(custom_attributes: appointment.custom_attributes.to_h.merge(
      'medelement_cabinet_code' => 'cabinet-1',
      status::ATTRIBUTE_KEY => status::PENDING,
      status::COMMAND_ID_KEY => command.id,
      status::COMMAND_IDEMPOTENCY_KEY => command.idempotency_key,
      status::COMMAND_FINGERPRINT_KEY => 'fingerprint-1',
      status::COMMAND_DISPATCH_IDENTITY_KEY => 'dispatch-1'
    ))
    appointment.medelement_provider_command_receipt = command
  end

  def acknowledge_write!(code = 'reception-1')
    command.update!(provider_reception_code: code, execution_state: command.execution_state.merge(
      'write_provider_reception_code' => code, 'write_provider_patient_code' => 'patient-1'
    ))
  end

  def prepare_reception_success!
    command.update!(execution_state: command.execution_state.merge(
      'request_snapshot' => command.request_snapshot.deep_merge(
        'version' => Integrations::Medelement::ProviderCommands::RequestSnapshotSchema::VERSION,
        'company_cabinet_code' => 'cabinet-1',
        'reception' => {
          'resource_id' => resource.id, 'destination_ends_at' => appointment.ends_at.iso8601,
          'nomenclature_codes' => []
        }
      )
    ))
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-1'))
  end

  def apply_reception!(reception_code, patient_code)
    applier = Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
    applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
  end

  it 'accepts a nonempty ID from this command before read-back, without an automatic customer message' do
    acknowledge_write!
    expect(service.perform).to eq(command)
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  it 'does not accept a provider ID that was not returned by the write' do
    command.update!(status: 'succeeded', provider_reception_code: 'readback-only')
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'does not confirm a zero ID returned by a create POST' do
    acknowledge_write!('0')
    allow(service).to receive(:monotonic_now).and_return(0, described_class::WAIT_SECONDS + 1)

    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'preserves a verified read-back success if it arrived during the wait without a write ID' do
    expect(service).to receive(:sleep).once do
      command.update!(status: 'succeeded', provider_reception_code: 'readback-only')
      status.persist!(appointment, status::SUCCEEDED, command: command)
    end
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::SUCCEEDED)
  end

  it 'keeps the local slot red and does not retry a timed-out create' do
    allow(service).to receive(:monotonic_now).and_return(0, described_class::WAIT_SECONDS + 1)
    expect(Integrations::Medelement::ProviderCommandJob).not_to receive(:perform_later)
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
    expect(appointment.reload.status).to eq('scheduled')
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'waits for asynchronous command confirmation rather than declaring an immediate rejection' do
    command.update!(status: 'awaiting_confirmation')
    allow(service).to receive(:monotonic_now).and_return(0, described_class::WAIT_SECONDS + 1)
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'marks a provider rejection red without deleting the local booking' do
    command.update!(status: 'failed', last_error_code: 'provider_http_error')
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_FAILED') }
    expect(appointment.reload.status).to eq('scheduled')
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::FAILED)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end

  it 'does not mistake a patient-action-required state for a confirmed booking' do
    command.update!(status: 'awaiting_patient_selection')
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_FAILED') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::FAILED)
  end

  it 'rejects a reception ID from a superseded appointment binding' do
    acknowledge_write!
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::COMMAND_ID_KEY => command.id + 1))
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
  end

  it 'does not confirm the old specialist when the local booking moves to another doctor at the same time' do
    prepare_reception_success!
    acknowledge_write!
    replacement = create(:scheduling_resource, account: account, custom_attributes: {})
    appointment.update!(resource: replacement)

    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
    expect(appointment.reload.resource_id).to eq(replacement.id)
  end

  it 'does not confirm the original interval when only the end time changes' do
    acknowledge_write!
    appointment.update!(ends_at: appointment.ends_at + 30.minutes)

    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
  end

  it 'does not confirm the original cabinet when the local booking changes cabinet' do
    acknowledge_write!
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-2'))

    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
  end

  it 'does not confirm the original services when the local booking changes service' do
    acknowledge_write!
    replacement = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'new-service' }
    )
    appointment.update!(service: replacement)

    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
  end

  it 'rejects a command created by a different Captain assistant' do
    other_assistant = create(:captain_assistant, account: account)
    other_service = described_class.new(appointment: appointment, assistant: other_assistant)
    expect { other_service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_SUPERSEDED') }
  end

  it 'does not apply a stale reconciliation error to a replacement booking' do
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::COMMAND_ID_KEY => command.id + 1))
    command.update!(status: 'reconciliation_required')

    Integrations::Medelement::ProviderCommands::ReconciliationLifecycle.new(command: command).defer_unknown!('readback_unavailable')

    expect(command.reload).to be_provider_status_unknown
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
  end

  it 'does not apply a late rejected write to a replacement booking' do
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::COMMAND_ID_KEY => command.id + 1))
    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
    command.update!(execution_state: command.execution_state.merge('claim_token' => executor.send(:claim_token)))

    executor.send(:fail_command!, code: 'provider_rejected')

    expect(command.reload).to be_failed
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
  end

  it 'does not let a late successful write overwrite a replacement booking bound to another command' do
    prepare_reception_success!
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::COMMAND_ID_KEY => command.id + 1))
    command.update!(status: 'processing')

    expect do
      apply_reception!('old-reception', 'old-patient')
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }

    expect(appointment.reload.external_ref).to be_nil
    expect(appointment.custom_attributes).to include(status::COMMAND_ID_KEY => command.id + 1)
    expect(command.reload).to be_processing
  end

  it 'does not let a late successful write overwrite a replacement booking before its new command is bound' do
    prepare_reception_success!
    appointment.update!(custom_attributes: appointment.custom_attributes.except(*status::COMMAND_BINDING_KEYS))
    command.update!(status: 'processing')

    expect do
      apply_reception!('old-reception', 'old-patient')
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }

    expect(appointment.reload.external_ref).to be_nil
    expect(appointment.custom_attributes[status::COMMAND_ID_KEY]).to be_nil
    expect(command.reload).to be_processing
  end

  it 'still applies a successful write for the current booking' do
    prepare_reception_success!

    expect do
      apply_reception!('current-reception', 'patient-1')
    end.to change { command.reload.status }.from('processing').to('succeeded')

    expect(appointment.reload.external_ref).to eq('medelement:reception:current-reception')
  end

  it 'allows a current provider write that finishes before the command binding is projected' do
    prepare_reception_success!
    travel_to(command.created_at - 1.second) do
      appointment.update!(custom_attributes: appointment.custom_attributes.except(*status::COMMAND_BINDING_KEYS))
    end

    expect { apply_reception!('early-reception', 'patient-1') }
      .to change { command.reload.status }.from('processing').to('succeeded')

    expect(appointment.reload.external_ref).to eq('medelement:reception:early-reception')
  end

  it 'keeps the local appointment and marks an absent command receipt for staff review' do
    appointment.medelement_provider_command_receipt = nil
    expect { service.perform }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE')
    end
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'needs no provider receipt for an unmapped doctor with a local-only booking' do
    resource.update!(custom_attributes: {})
    appointment.update!(custom_attributes: appointment.custom_attributes.except(status::ATTRIBUTE_KEY))
    appointment.medelement_provider_command_receipt = nil
    expect(service.perform).to be_nil
  end

  it 'accepts a local-only booking when the clinic has disabled the MedElement write hook' do
    hook.update!(status: 'disabled')
    appointment.update!(custom_attributes: appointment.custom_attributes.except(status::ATTRIBUTE_KEY, *status::COMMAND_BINDING_KEYS))
    appointment.medelement_provider_command_receipt = nil

    expect(service.perform).to be_nil
  end

  it 'still checks an existing provider command if the doctor mapping later changes' do
    resource.update!(custom_attributes: {})
    allow(service).to receive(:monotonic_now).and_return(0, described_class::WAIT_SECONDS + 1)
    expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_UNKNOWN') }
  end
end
