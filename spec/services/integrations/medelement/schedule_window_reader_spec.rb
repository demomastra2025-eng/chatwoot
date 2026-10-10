require 'rails_helper'

RSpec.describe Integrations::Medelement::ScheduleWindowReader do
  let(:date) { Date.new(2026, 9, 7) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }

  def read(payload, ends_on: date)
    described_class.new(payload: payload, starts_on: date, ends_on: ends_on, time_zone: zone).perform
  end

  it 'uses the provider clock and preserves the cabinet attached to a confirmed interval' do
    payload = { '07.09.2026' => { 'timetable' => [
      { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 10:00', 'working' => ' TRUE ', 'cabinetCode' => '101' }
    ] } }

    expect(read(payload)).to eq([[zone.local(2026, 9, 7, 9), zone.local(2026, 9, 7, 10), '101']])
  end

  it 'accepts an explicitly confirmed day off' do
    expect(read({ '07.09.2026' => { 'specialistWorkingHours' => 'day off', 'timetable' => [] } })).to eq([])
  end

  it 'rejects an empty day without closure evidence' do
    expect { read({ '07.09.2026' => { 'timetable' => [] } }) }
      .to raise_error(Integrations::Medelement::Client::InvalidTimetableError)
  end

  it 'rejects an omitted requested day even when the first day is confirmed' do
    payload = { '07.09.2026' => { 'specialistWorkingHours' => 'day off', 'timetable' => [] } }
    expect { read(payload, ends_on: date + 1) }.to raise_error(Integrations::Medelement::Client::InvalidTimetableError)
  end

  it 'rejects a row whose working state or date is not confirmed' do
    [{ 'working' => 'unknown', 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 10:00' },
     { 'working' => true, 'start' => '08.09.2026 09:00', 'end' => '08.09.2026 10:00' }].each do |row|
      expect { read({ '07.09.2026' => { 'timetable' => [row] } }) }
        .to raise_error(Integrations::Medelement::Client::InvalidTimetableError)
    end
  end
end
