require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderStatus do
  let(:appointment) do
    create(
      :scheduling_appointment,
      status: 'cancelled',
      custom_attributes: {
        described_class::ATTRIBUTE_KEY => described_class::SUCCEEDED,
        described_class::COMMAND_ID_KEY => 40,
        described_class::COMMAND_IDEMPOTENCY_KEY => 'old-command',
        described_class::COMMAND_FINGERPRINT_KEY => 'old-fingerprint',
        described_class::COMMAND_DISPATCH_IDENTITY_KEY => 'old-event',
        described_class::CANCELLATION_COMMAND_ID_KEY => 41
      }
    )
  end

  it 'clears a stale cancellation command when a new cancellation intent becomes pending' do
    described_class.assign_pending!(appointment)

    expect(appointment.custom_attributes).to include(described_class::ATTRIBUTE_KEY => described_class::PENDING)
    expect(appointment.custom_attributes).not_to have_key(described_class::COMMAND_ID_KEY)
    expect(appointment.custom_attributes).not_to have_key(described_class::COMMAND_IDEMPOTENCY_KEY)
    expect(appointment.custom_attributes).not_to have_key(described_class::COMMAND_FINGERPRINT_KEY)
    expect(appointment.custom_attributes).not_to have_key(described_class::COMMAND_DISPATCH_IDENTITY_KEY)
    expect(appointment.custom_attributes).not_to have_key(described_class::CANCELLATION_COMMAND_ID_KEY)
  end

  it 'atomically projects the current remove command with its provider status' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      id: 42,
      idempotency_key: 'remove-command',
      execution_state: { 'request_fingerprint' => 'f' * 64, 'dispatch_identity' => 'onelink-event:remove:42' },
      remove_reception?: true
    )

    described_class.persist!(appointment, described_class::PENDING, command: command)

    expect(appointment.reload.custom_attributes).to include(
      described_class::ATTRIBUTE_KEY => described_class::PENDING,
      described_class::COMMAND_ID_KEY => command.id,
      described_class::COMMAND_IDEMPOTENCY_KEY => 'remove-command',
      described_class::COMMAND_FINGERPRINT_KEY => 'f' * 64,
      described_class::COMMAND_DISPATCH_IDENTITY_KEY => 'onelink-event:remove:42',
      described_class::CANCELLATION_COMMAND_ID_KEY => command.id
    )
  end
end
