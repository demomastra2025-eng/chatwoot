require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentResult do
  it 'does not report an asynchronous provider move or removal as completed' do
    appointment = create(:scheduling_appointment, custom_attributes: { 'medelement_provider_sync_status' => 'pending' })
    %w[update_appointment cancel_appointment].each do |action|
      expect(described_class.success(appointment, action: action)).to include(
        success: false, reason: 'pending_provider_confirmation', status: 'pending_provider_confirmation', provider_confirmed: false
      )
    end
  end

  it 'makes a local-only cancellation explicit and preserves the provider reception' do
    appointment = create(:scheduling_appointment, status: 'cancelled', custom_attributes: {
                           'medelement_provider_sync_status' => 'succeeded', 'medelement_local_cancellation' => { 'at' => Time.current.iso8601 }
                         })
    expect(described_class.success(appointment, action: 'cancel_appointment')).to include(
      success: true, status: 'cancelled_local_only', cancellation_scope: 'onelink_only', provider_reception_active: true
    )
  end

  it 'uses the exact queued command receipt instead of an older successful appointment status' do
    appointment = create(:scheduling_appointment, source: 'medelement', custom_attributes: { 'medelement_provider_sync_status' => 'succeeded' })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, succeeded?: false, provider_status_unknown?: false, terminal?: false
    )
    expect(described_class.success(appointment, action: 'update_appointment')).to include(
      success: false, status: 'pending_provider_confirmation', reason: 'pending_provider_confirmation', provider_confirmed: false
    )
    expect(appointment.custom_attributes['medelement_provider_sync_status']).to eq('succeeded')
  end

  it 'does not turn a failed exact receipt into success after an earlier provider operation' do
    appointment = create(:scheduling_appointment, custom_attributes: { 'medelement_provider_sync_status' => 'succeeded' })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, succeeded?: false, provider_status_unknown?: false, terminal?: true
    )
    expect(described_class.success(appointment, action: 'cancel_appointment')).to include(
      success: false, status: 'provider_confirmation_failed', reason: 'staff_will_help', provider_confirmed: false
    )
  end

  it 'maps only verified slot conflicts to time_taken' do
    conflict = Scheduling::Error.new(code: 'APPOINTMENT_SLOT_UNAVAILABLE', message: 'Unavailable', status: :conflict)
    unknown = Scheduling::Error.new(code: 'MEDELEMENT_AVAILABILITY_UNVERIFIED', message: 'Unknown', status: :service_unavailable)

    expect(described_class.failure(conflict)).to eq(success: false, reason: 'time_taken')
    expect(described_class.failure(unknown)).to eq(success: false, reason: 'staff_will_help')
  end

  it 'maps the provider horizon and includes only the last bookable date' do
    error = Scheduling::Error.new(
      code: 'MEDELEMENT_HORIZON_EXCEEDED', message: 'Do not expose this text', status: :unprocessable_content,
      details: { last_available_date: '2026-10-15', provider_code: 'internal' }
    )

    expect(described_class.failure(error)).to eq(success: false, reason: 'schedule_not_open', last_available_date: '2026-10-15')
  end

  it 'maps the 45-second unknown and failed outcomes to staff_will_help' do
    %w[MEDELEMENT_BOOKING_UNKNOWN MEDELEMENT_BOOKING_FAILED].each do |code|
      error = Scheduling::Error.new(code: code, message: 'Provider details', status: :unprocessable_content)
      expect(described_class.failure(error)).to eq(success: false, reason: 'staff_will_help')
    end
  end
end
