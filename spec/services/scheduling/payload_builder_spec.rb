require 'rails_helper'

RSpec.describe Scheduling::PayloadBuilder do
  it 'includes the operation receipt attached to a provider-backed mutation' do
    appointment = build_stubbed(:scheduling_appointment)
    command = instance_double(Integrations::Medelement::ProviderCommand)
    receipt = { appointment_id: appointment.id, expected_operation: 'move_reception' }
    appointment.medelement_provider_command_receipt = command
    allow(Integrations::Medelement::ProviderCommandReceiptBuilder).to receive(:build)
      .with(command: command)
      .and_return(receipt)

    payload = described_class.appointment(appointment)

    expect(payload[:provider_command_receipt]).to eq(receipt)
  end
end
