require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentResult do
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
