require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderStatus do
  let(:appointment) do
    create(
      :scheduling_appointment,
      status: 'cancelled',
      custom_attributes: {
        described_class::ATTRIBUTE_KEY => described_class::SUCCEEDED,
        described_class::CANCELLATION_COMMAND_ID_KEY => 41
      }
    )
  end

  it 'clears a stale cancellation command when a new cancellation intent becomes pending' do
    described_class.assign_pending!(appointment)

    expect(appointment.custom_attributes).to include(described_class::ATTRIBUTE_KEY => described_class::PENDING)
    expect(appointment.custom_attributes).not_to have_key(described_class::CANCELLATION_COMMAND_ID_KEY)
  end

  it 'atomically projects the current remove command with its provider status' do
    command = instance_double(Integrations::Medelement::ProviderCommand, id: 42, remove_reception?: true)

    described_class.persist!(appointment, described_class::PENDING, command: command)

    expect(appointment.reload.custom_attributes).to include(
      described_class::ATTRIBUTE_KEY => described_class::PENDING,
      described_class::CANCELLATION_COMMAND_ID_KEY => command.id
    )
  end
end
