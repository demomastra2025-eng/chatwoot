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
end
