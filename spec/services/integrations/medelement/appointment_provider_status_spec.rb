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
      operation: 'remove_reception',
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

  it 'does not use a successful move as confirmation of a later local cancellation' do
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(
      described_class::OPERATION_KEY => 'move_reception',
      Integrations::Medelement::LocalCancellation::MARKER_KEY => { 'reception_code' => 'reception-1' }
    ))

    expect(described_class.payload(appointment)).to include(
      provider_confirmed: false, provider_confirmation_status: 'not_requested',
      provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink'
    )
    expect(described_class.cancellation_confirmed?(appointment)).to be(false)
  end

  it 'requires the cancellation receipt to match the current operation even for an older unmarked cancellation' do
    expect(described_class.payload(appointment)[:provider_confirmed]).to be(false)
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(
      described_class::OPERATION_KEY => 'move_reception', described_class::CANCELLATION_COMMAND_ID_KEY => 40
    ))
    expect(described_class.payload(appointment)[:provider_confirmed]).to be(false)

    appointment.update!(custom_attributes: appointment.custom_attributes.merge(described_class::OPERATION_KEY => 'remove_reception'))
    expect(described_class.payload(appointment)).to include(provider_confirmed: true, provider_confirmation_operation: 'remove_reception')
  end
end
