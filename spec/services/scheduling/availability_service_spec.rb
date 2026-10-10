require 'rails_helper'

RSpec.describe Scheduling::AvailabilityService do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:booking_day) { ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 9, 10, 0, 0) }
  let!(:work_rule) do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
  end

  subject(:service) do
    described_class.new(
      resource: resource,
      from: booking_day.beginning_of_day,
      to: booking_day.end_of_day,
      holidays: holidays,
      workday_overrides: workday_overrides,
      time_offs: time_offs,
      appointments: appointments
    )
  end

  let(:holidays) { [] }
  let(:workday_overrides) { [] }
  let(:time_offs) { [] }
  let(:appointments) { [] }

  it 'returns BLOCKED_BY_HOLIDAY when the day is blocked' do
    holidays << create(:scheduling_holiday, account: account, date: booking_day.to_date)

    result = service.availability_result(starts_at: booking_day, ends_at: booking_day + 30.minutes)

    expect(result.available?).to be(false)
    expect(result.code).to eq('BLOCKED_BY_HOLIDAY')
  end

  it 'returns BLOCKED_BY_BREAK when the slot overlaps a break' do
    create(:scheduling_break_rule, resource: resource, account: account, weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60)

    result = service.availability_result(starts_at: booking_day + 15.minutes, ends_at: booking_day + 45.minutes)

    expect(result.available?).to be(false)
    expect(result.code).to eq('BLOCKED_BY_BREAK')
  end

  it 'returns BLOCKED_BY_VACATION when the slot overlaps time off' do
    time_offs << create(:scheduling_time_off, resource: resource, account: account, starts_at: booking_day, ends_at: booking_day + 1.hour)

    result = service.availability_result(starts_at: booking_day + 15.minutes, ends_at: booking_day + 45.minutes)

    expect(result.available?).to be(false)
    expect(result.code).to eq('BLOCKED_BY_VACATION')
  end

  it 'returns SLOT_CONFLICT when the slot overlaps another appointment' do
    appointments << create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      starts_at: booking_day,
      ends_at: booking_day + 1.hour
    )

    result = service.availability_result(starts_at: booking_day + 15.minutes, ends_at: booking_day + 45.minutes)

    expect(result.available?).to be(false)
    expect(result.code).to eq('SLOT_CONFLICT')
  end

  it 'returns OUTSIDE_WORKING_HOURS when the slot spans multiple local days' do
    result = service.availability_result(starts_at: booking_day.end_of_day - 10.minutes, ends_at: booking_day.end_of_day + 30.minutes)

    expect(result.available?).to be(false)
    expect(result.code).to eq('OUTSIDE_WORKING_HOURS')
  end

  it 'keeps a locally cancelled provider reception occupied until its provider removal is confirmed' do
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment = create(:scheduling_appointment, account: account, resource: resource, status: 'cancelled', source: 'medelement',
                                                starts_at: booking_day, ends_at: booking_day + 1.hour,
                                                external_ref: 'medelement:reception:reception-1', custom_attributes: {
                                                  Integrations::Medelement::LocalCancellation::MARKER_KEY => true,
                                                  status::ATTRIBUTE_KEY => 'succeeded', status::OPERATION_KEY => 'move_reception'
                                                })
    appointments << appointment

    expect(service.availability_result(starts_at: booking_day, ends_at: booking_day + 30.minutes).code).to eq('SLOT_CONFLICT')
    expect(service.slots(duration_min: 30)).not_to include(include(starts_at: booking_day.iso8601))

    appointment.mark_medelement_provider_reconciled!
    appointment.update!(custom_attributes: {
      status::ATTRIBUTE_KEY => 'succeeded', status::OPERATION_KEY => 'remove_reception',
      status::COMMAND_ID_KEY => 42, status::CANCELLATION_COMMAND_ID_KEY => 42
    })
    expect(service.availability_result(starts_at: booking_day, ends_at: booking_day + 30.minutes)).to be_available
  end

  it 'keeps older unmarked provider cancellations blocked but frees ordinary local cancellations' do
    appointments << build(:scheduling_appointment, id: 41, resource: resource, account: account, status: 'cancelled', source: 'medelement',
                                                 external_ref: 'medelement:reception:legacy', starts_at: booking_day, ends_at: booking_day + 1.hour)
    expect(service.availability_result(starts_at: booking_day, ends_at: booking_day + 30.minutes).code).to eq('SLOT_CONFLICT')

    appointments.clear
    appointments << build(:scheduling_appointment, id: 42, resource: resource, account: account, status: 'cancelled',
                                                 starts_at: booking_day, ends_at: booking_day + 1.hour)
    expect(service.availability_result(starts_at: booking_day, ends_at: booking_day + 30.minutes)).to be_available
  end
end
