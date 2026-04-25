require 'rails_helper'

RSpec.describe Scheduling::ResourceScheduleService do
  let(:account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty') }
  let(:monday) { time_zone.local(2026, 4, 20, 0, 0, 0) }
  let(:tuesday) { monday + 1.day }

  before do
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_break_rule, account: account, resource: resource, weekday: 1, start_minute: 13 * 60, end_minute: 14 * 60, title: 'Lunch')
  end

  def perform(from: monday, to: tuesday, **attributes)
    described_class.new(resource: resource, from: from, to: to, **attributes).perform
  end

  it 'returns normalized windows, breaks, holidays, and clipped time-offs in the resource timezone' do
    create(:scheduling_holiday, account: account, date: monday.to_date, title: 'Clinic day', working_day_override: true)
    create(:scheduling_time_off, account: account, resource: resource, starts_at: time_zone.local(2026, 4, 20, 8, 0),
                                 ends_at: time_zone.local(2026, 4, 20, 11, 0), title: 'Morning block')
    create(:scheduling_time_off, account: account, resource: nil, starts_at: time_zone.local(2026, 4, 20, 14, 0),
                                 ends_at: time_zone.local(2026, 4, 20, 16, 0), title: 'Clinic block')

    payload = perform(from: time_zone.local(2026, 4, 20, 10, 0), to: time_zone.local(2026, 4, 20, 15, 0))
    day = payload[:days].first

    expect(payload[:timezone]).to eq('Asia/Almaty')
    expect(day[:working]).to be(true)
    expect(day[:source]).to eq('weekly_rules')
    expect(day[:windows]).to eq([
                                  { start_at: '2026-04-20T10:00:00+05:00', end_at: '2026-04-20T15:00:00+05:00' }
                                ])
    expect(day[:breaks]).to eq([
                                 { start_at: '2026-04-20T13:00:00+05:00', end_at: '2026-04-20T14:00:00+05:00', title: 'Lunch' }
                               ])
    expect(day[:holidays]).to eq([
                                   { title: 'Clinic day', working_day_override: true, recurring_yearly: false }
                                 ])
    expect(day[:time_offs]).to eq([
                                    { start_at: '2026-04-20T10:00:00+05:00', end_at: '2026-04-20T11:00:00+05:00', title: 'Morning block',
                                      kind: 'vacation' },
                                    { start_at: '2026-04-20T14:00:00+05:00', end_at: '2026-04-20T15:00:00+05:00', title: 'Clinic block',
                                      kind: 'vacation' }
                                  ])
  end

  it 'prefers a workday override over a blocking holiday and weekly rules' do
    create(:scheduling_holiday, account: account, date: monday.to_date, title: 'Holiday')
    create(
      :scheduling_workday_override,
      account: account,
      resource: resource,
      date: monday.to_date,
      start_minute: 10 * 60,
      end_minute: 16 * 60,
      break_start_minute: 12 * 60,
      break_end_minute: 13 * 60
    )

    day = perform[:days].first

    expect(day[:working]).to be(true)
    expect(day[:source]).to eq('override')
    expect(day[:windows]).to eq([
                                  { start_at: '2026-04-20T10:00:00+05:00', end_at: '2026-04-20T16:00:00+05:00' }
                                ])
    expect(day[:breaks]).to eq([
                                 { start_at: '2026-04-20T12:00:00+05:00', end_at: '2026-04-20T13:00:00+05:00', title: 'Break' }
                               ])
  end

  it 'honors include toggles without changing the working-day calculation' do
    create(:scheduling_holiday, account: account, date: monday.to_date, title: 'Clinic day', working_day_override: true)
    create(:scheduling_time_off, account: account, resource: resource, starts_at: time_zone.local(2026, 4, 20, 10, 0),
                                 ends_at: time_zone.local(2026, 4, 20, 11, 0))

    day = perform(include_breaks: false, include_holidays: false, include_time_offs: false)[:days].first

    expect(day[:working]).to be(true)
    expect(day[:breaks]).to eq([])
    expect(day[:holidays]).to eq([])
    expect(day[:time_offs]).to eq([])
  end

  it 'rejects reversed ranges at the domain layer' do
    expect { perform(from: tuesday, to: monday) }.to raise_error(ArgumentError, 'to must be greater than from')
  end

  it 'rejects ranges larger than the scheduling safety window at the domain layer' do
    expect { perform(from: monday, to: monday + 32.days) }.to raise_error(ArgumentError, 'Date range must be 31 days or less')
  end
end
