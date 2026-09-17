require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderCommandReceiptLookupService do
  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account) }
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

  def create_command(operation:, status:, command_idempotency_key: idempotency_key, command_dispatch_identity: dispatch_identity,
                     command_fingerprint: fingerprint)
    attributes = {
      account: account,
      appointment: appointment,
      contact: appointment.contact,
      operation: operation,
      status: status,
      idempotency_key: command_idempotency_key,
      execution_state: {
        'request_fingerprint' => command_fingerprint,
        'dispatch_identity' => command_dispatch_identity
      }
    }
    attributes[:company_cabinet_code] = 'cabinet-1' if operation.in?(%w[create_reception move_reception])
    if operation == 'move_reception'
      attributes[:desired_starts_at] = appointment.starts_at + 1.hour
      attributes[:desired_ends_at] = appointment.ends_at + 1.hour
    end

    Integrations::Medelement::ProviderCommand.create!(attributes)
  end

  %w[create_reception move_reception remove_reception].product(%w[awaiting_confirmation processing succeeded failed]).each do |operation, status|
    it "attaches the exact #{status} #{operation} command" do
      command = create_command(operation: operation, status: status)
      bind_appointment(
        command_id: command.id,
        fingerprint: fingerprint,
        idempotency_key: idempotency_key,
        dispatch_identity: dispatch_identity
      )

      result = described_class.new(account: account, appointment: appointment, operation: operation).perform

      expect(result).to eq(command)
      expect(appointment.medelement_provider_command_receipt).to eq(command)
    end
  end

  %w[create_reception move_reception remove_reception].each do |operation|
    it "does not attach an older #{operation} command with a different event and idempotency identity" do
      stale_command = create_command(
        operation: operation,
        status: 'succeeded',
        command_idempotency_key: "stale-#{operation}",
        command_dispatch_identity: "onelink-event:stale:#{operation}"
      )
      bind_appointment(
        command_id: stale_command.id,
        fingerprint: fingerprint,
        idempotency_key: "current-#{operation}",
        dispatch_identity: "onelink-event:current:#{operation}"
      )

      result = described_class.new(account: account, appointment: appointment, operation: operation).perform

      expect(result).to be_nil
      expect(appointment.medelement_provider_command_receipt).to be_nil
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

  %w[create_reception move_reception remove_reception].each do |operation|
    it "fails closed while a pending #{operation} mutation has no durable exact command" do
      pending_attributes = {
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY =>
          Integrations::Medelement::AppointmentProviderStatus::PENDING
      }
      appointment.custom_attributes = pending_attributes

      expect do
        described_class.new(account: account, appointment: appointment, operation: operation).perform
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE') }
    end
  end
end
