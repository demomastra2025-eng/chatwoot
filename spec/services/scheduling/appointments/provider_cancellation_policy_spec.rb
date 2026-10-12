require 'rails_helper'

RSpec.describe Scheduling::Appointments::ProviderCancellationPolicy do
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:move_key) { Integrations::Medelement::AppointmentMoveState::ATTRIBUTE_KEY }

  def appointment_with(sync_status, move_state = nil)
    attributes = { 'medelement_reception_code' => 'reception-1', status::ATTRIBUTE_KEY => sync_status }
    attributes[move_key] = { 'state' => move_state } if move_state
    create(:scheduling_appointment, external_ref: 'medelement:reception:reception-1', custom_attributes: attributes)
  end

  it 'keeps a reception removable after a rejected reschedule left it at the confirmed time' do
    expect(described_class.new(appointment: appointment_with(status::FAILED, 'rejected'))).to be_confirmed_for_removal
  end

  it 'does not treat a failed booking without a verified rejection as confirmed' do
    expect(described_class.new(appointment: appointment_with(status::FAILED))).not_to be_confirmed_for_removal
  end

  it 'does not remove a reception while the reschedule outcome is unknown or still pending' do
    expect(described_class.new(appointment: appointment_with(status::UNKNOWN, 'needs_reconciliation'))).not_to be_confirmed_for_removal
    expect(described_class.new(appointment: appointment_with(status::PENDING, 'pending'))).not_to be_confirmed_for_removal
  end
end
