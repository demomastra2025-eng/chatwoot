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

  it 'exposes a reschedule MedElement has not confirmed next to the confirmed time, never as the appointment time' do
    appointment = build_stubbed(:scheduling_appointment, starts_at: Time.utc(2026, 10, 15, 5, 0), ends_at: Time.utc(2026, 10, 15, 5, 30))
    appointment.custom_attributes = {
      'medelement_provider_sync_status' => 'provider_status_unknown', 'medelement_provider_operation' => 'move_reception',
      'medelement_move_request' => {
        'state' => 'needs_reconciliation', 'command_id' => 160, 'error_code' => 'provider_http_error', 'error_status' => 400,
        'confirmed_starts_at' => '2026-10-15T05:00:00.000000Z', 'requested_starts_at' => '2026-10-14T05:30:00.000000Z'
      }
    }

    payload = described_class.appointment(appointment)

    expect(payload).to include(
      starts_at: appointment.starts_at.iso8601, provider_confirmed: false, provider_confirmation_status: 'provider_status_unknown'
    )
    expect(payload[:provider_move]).to include(
      state: 'needs_reconciliation', requested_time_confirmed: false, needs_reconciliation: true, command_id: 160,
      confirmed_starts_at: '2026-10-15T05:00:00.000000Z', requested_starts_at: '2026-10-14T05:30:00.000000Z', error_status: 400
    )
    expect(Scheduling::ToolPayloadBuilder.appointment_payload(action: 'update_appointment', appointment: appointment))
      .to include(starts_at: appointment.starts_at.iso8601, status: 'provider_status_unknown', provider_move: payload[:provider_move])
  end

  it 'adds no reschedule state to an appointment without one' do
    expect(described_class.appointment(build_stubbed(:scheduling_appointment))).not_to have_key(:provider_move)
  end
end
