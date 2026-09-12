require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderCommandReceiptLookupService do
  let(:account) { build_stubbed(:account) }
  let(:appointment) { build_stubbed(:scheduling_appointment, account: account) }
  let(:fingerprint) { 'f' * 64 }
  let(:idempotency_key) { 'exact-request-key' }
  let(:dispatch_identity) { 'onelink-event:create:1' }

  def bind_appointment(command_id:, fingerprint:, idempotency_key:, dispatch_identity:)
    appointment.custom_attributes = {
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY => command_id,
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_IDEMPOTENCY_KEY => idempotency_key,
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_FINGERPRINT_KEY => fingerprint,
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_DISPATCH_IDENTITY_KEY => dispatch_identity
    }
  end

  %w[create_reception move_reception remove_reception].product(%w[succeeded processing failed v2_awaiting_confirmation]).each do |operation, status|
    it "attaches the exact #{status} #{operation} command" do
      command = instance_double(
        Integrations::Medelement::ProviderCommand,
        execution_state: { 'request_fingerprint' => fingerprint, 'dispatch_identity' => dispatch_identity },
        status: status
      )
      bind_appointment(
        command_id: 41,
        fingerprint: fingerprint,
        idempotency_key: idempotency_key,
        dispatch_identity: dispatch_identity
      )
      expect(Integrations::Medelement::ProviderCommand).to receive(:find_by).with(
        id: 41,
        account_id: account.id,
        appointment_id: appointment.id,
        operation: operation,
        idempotency_key: idempotency_key
      ).and_return(command)

      result = described_class.new(account: account, appointment: appointment, operation: operation).perform

      expect(result).to eq(command)
      expect(appointment.medelement_provider_command_receipt).to eq(command)
    end
  end

  it 'does not attach an older command of the same operation when the exact binding is missing' do
    appointment.custom_attributes = {}
    allow(Integrations::Medelement::ProviderCommand).to receive(:find_by)

    result = described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform

    expect(result).to be_nil
    expect(Integrations::Medelement::ProviderCommand).not_to have_received(:find_by)
  end

  it 'does not attach a command when the request fingerprint differs' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      execution_state: { 'request_fingerprint' => 'a' * 64, 'dispatch_identity' => dispatch_identity }
    )
    bind_appointment(command_id: 41, fingerprint: fingerprint, idempotency_key: idempotency_key, dispatch_identity: dispatch_identity)
    allow(Integrations::Medelement::ProviderCommand).to receive(:find_by).and_return(command)

    result = described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform

    expect(result).to be_nil
  end

  it 'does not attach a command when the dispatch identity differs' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      execution_state: { 'request_fingerprint' => fingerprint, 'dispatch_identity' => 'onelink-event:create:old' }
    )
    bind_appointment(command_id: 41, fingerprint: fingerprint, idempotency_key: idempotency_key, dispatch_identity: dispatch_identity)
    allow(Integrations::Medelement::ProviderCommand).to receive(:find_by).and_return(command)

    result = described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform

    expect(result).to be_nil
  end

  it 'fails closed while a pending provider mutation has no durable command' do
    pending_attributes = {
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY =>
        Integrations::Medelement::AppointmentProviderStatus::PENDING
    }
    appointment.custom_attributes = pending_attributes

    expect do
      described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE') }
  end
end
