require 'rails_helper'

RSpec.describe Scheduling::SlotConflictDetails do
  let(:resource) { instance_double(Scheduling::Resource, timezone: 'Asia/Almaty') }
  let(:busy_start) { Time.iso8601('2026-10-29T15:30:00+05:00') }
  let(:busy_end) { Time.iso8601('2026-10-29T17:00:00+05:00') }
  let(:visits) do
    [
      Struct.new(:id, :status, :starts_at, :ends_at).new(1, 'scheduled', busy_start, busy_start + 30.minutes),
      Struct.new(:id, :status, :starts_at, :ends_at).new(2, 'scheduled', busy_start + 30.minutes, busy_end)
    ]
  end
  let(:availability) do
    instance_double(Scheduling::AvailabilityService, resource: resource, appointments: visits, ignore_appointment_id: nil)
  end

  it 'merges touching visits and selects two fitting starts on either side' do
    starts = %w[14:30 15:00 15:30 17:00 17:30 18:00].map do |clock|
      { starts_at: "2026-10-29T#{clock}:00+05:00" }
    end
    allow(availability).to receive(:slots).with(duration_min: 30).and_return(starts)
    travel_to Time.iso8601('2026-10-29T13:00:00+05:00') do
      result = described_class.new(availability: availability, starts_at: busy_start, ends_at: busy_start + 30.minutes).perform
      expect(result).to eq(
        busy: { starts_at: busy_start.iso8601, ends_at: busy_end.iso8601 },
        time_zone: 'Asia/Almaty',
        free_starts: %w[14:30 15:00 17:00 17:30].map { |clock| "2026-10-29T#{clock}:00+05:00" }
      )
    end
  end

  it 'returns an empty array when the known grid has no fitting starts' do
    allow(availability).to receive(:slots).and_return([])
    result = described_class.new(availability: availability, starts_at: busy_start, ends_at: busy_end).perform
    expect(result[:free_starts]).to eq([])
  end

  it 'omits hints when the occupied interval is unknown' do
    expect(described_class.new(availability: availability, starts_at: busy_start, ends_at: busy_end,
                               occupied_intervals: []).perform).to eq({})
  end

  it 'does not describe a free gap as one busy block' do
    separate_visits = [
      Struct.new(:id, :status, :starts_at, :ends_at).new(1, 'scheduled', busy_start, busy_start + 30.minutes),
      Struct.new(:id, :status, :starts_at, :ends_at).new(2, 'scheduled', busy_start + 1.hour, busy_end)
    ]
    allow(availability).to receive(:appointments).and_return(separate_visits)

    result = described_class.new(availability: availability, starts_at: busy_start + 15.minutes,
                                 ends_at: busy_start + 75.minutes).perform

    expect(result).to eq({})
  end

  it 'uses the scheduling grid and working windows for the requested duration' do
    account = create(:account)
    doctor = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                          custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                               'medelement_reception_time' => 30 })
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    day = Date.new(2026, 10, 29)
    at = ->(hour, minute = 0) { zone.local(day.year, day.month, day.day, hour, minute) }
    travel_to at.call(14) do
      result = described_class.for_provider(
        resource: doctor, interval: [at.call(15, 30), at.call(16)],
        windows: [[at.call(14), at.call(18)]], receptions: [[at.call(15, 30), at.call(17)]]
      )

      expect(result[:free_starts]).to eq([at.call(14, 30), at.call(15), at.call(17), at.call(17, 30)].map(&:iso8601))
    end
  end

  it 'blocks the provider reception when choosing starts for a longer visit' do
    account = create(:account)
    doctor = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                          custom_attributes: { 'medelement_specialist_code' => 'doctor-1',
                                                               'medelement_reception_time' => 30 })
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    at = ->(hour, minute = 0) { zone.local(2026, 10, 29, hour, minute) }

    travel_to at.call(13) do
      result = described_class.for_provider(
        resource: doctor, interval: [at.call(15, 30), at.call(16, 15)],
        windows: [[at.call(14), at.call(18)]], receptions: [[at.call(15, 30), at.call(17)]]
      )

      expect(result[:busy]).to eq(starts_at: at.call(15, 30).iso8601, ends_at: at.call(17).iso8601)
      expect(result[:free_starts]).to eq([at.call(14), at.call(14, 30), at.call(17)].map(&:iso8601))
    end
  end

  it 'never offers starts from a different local day or from the past' do
    account = create(:account)
    doctor = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                          custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    midnight = zone.local(2026, 10, 30)
    travel_to midnight - 2.hours do
      result = described_class.for_provider(
        resource: doctor, interval: [midnight - 30.minutes, midnight],
        windows: [[midnight - 3.hours, midnight + 1.hour]],
        receptions: [[midnight - 30.minutes, midnight]]
      )

      expect(result[:free_starts]).to eq([(midnight - 90.minutes).iso8601, (midnight - 1.hour).iso8601])
    end
  end

  it 'omits free starts when the working windows were not obtained' do
    allow(availability).to receive(:slots).and_return([])
    result = described_class.new(availability: availability, starts_at: busy_start, ends_at: busy_end,
                                 free_starts_known: false).perform
    expect(result).to include(:busy, :time_zone)
    expect(result).not_to have_key(:free_starts)
  end
end
