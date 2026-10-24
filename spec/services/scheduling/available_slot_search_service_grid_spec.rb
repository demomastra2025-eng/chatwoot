require 'rails_helper'

# The slot search offers the starts on the grid of the specialist's cells, not on a five-minute step.
RSpec.describe Scheduling::AvailableSlotSearchService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:reception_time) { 10 }
  let(:grid_override) { nil }
  let(:resource) do
    attributes = { 'medelement_specialist_code' => 'specialist-1', 'medelement_reception_time' => reception_time,
                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] }
    attributes['slot_grid_min'] = grid_override if grid_override
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: reception_time, custom_attributes: attributes)
  end
  # 2026-04-21 is a Tuesday.
  let(:tuesday) { Date.new(2026, 4, 21) }

  before do
    account.enable_features!('scheduling')
    hook
  end

  # A confirmed day of the provider table with one working row per cell, as get_timetable gives them.
  def store_day(date, from_minute, to_minute, size: reception_time)
    windows = (from_minute...to_minute).step(size).map { |minute| { start_minute: minute, end_minute: minute + size } }
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1', date: date,
      status: 'confirmed', source_checked_at: Time.current, windows: windows
    )
  end

  def clock(payload)
    payload[:slots].map { |slot| Time.iso8601(slot[:starts_at]).in_time_zone(zone).strftime('%H:%M') }
  end

  def search(from: zone.local(2026, 4, 21, 9), to: zone.local(2026, 4, 22), **)
    described_class.new(account: account, resource_ids: [resource.id], from: from, to: to, **).perform
  end

  describe 'a doctor with a 10-minute grid on a Tuesday from 14:20 to 20:00' do
    before { store_day(tuesday, (14 * 60) + 20, 20 * 60) }

    it 'offers 14:20, 14:30 ... for a 20-minute visit and never 14:25' do
      starts = clock(search(duration_min: 20))

      expect(starts.first(4)).to eq(%w[14:20 14:30 14:40 14:50])
      expect(starts).not_to include('14:25')
      expect(starts.map { |time| time[-1] }.uniq).to eq(['0'])
      expect(starts.size).to eq(33)
      expect(starts.last).to eq('19:40')
    end

    it 'keeps the grid when the range begins between two cell starts' do
      payload = search(duration_min: 20, from: zone.local(2026, 4, 21, 14, 25), to: zone.local(2026, 4, 21, 15))

      expect(clock(payload)).to eq(%w[14:30 14:40 14:50])
    end

    it 'finds no start at a time between two cell starts' do
      payload = search(duration_min: 20, from: zone.local(2026, 4, 21, 14, 25), to: zone.local(2026, 4, 21, 14, 26))

      expect(payload[:slots]).to be_empty
    end

    it 'offers the cell starts for a visit that takes several cells' do
      payload = search(duration_min: 45, to: zone.local(2026, 4, 21, 15))

      expect(clock(payload)).to eq(%w[14:20 14:30 14:40 14:50])
      expect(payload[:slots].first[:ends_at]).to eq(zone.local(2026, 4, 21, 15, 5).iso8601)
    end
  end

  describe 'a doctor with 30-minute cells' do
    let(:reception_time) { 30 }

    before { store_day(tuesday, 9 * 60, 12 * 60) }

    it 'offers one start per cell' do
      expect(clock(search(duration_min: 30))).to eq(%w[09:00 09:30 10:00 10:30 11:00 11:30])
    end

    context 'with slot_grid_min 10' do
      let(:grid_override) { 10 }

      it 'offers the 10-minute starts inside the cells' do
        starts = clock(search(duration_min: 30))

        expect(starts.first(4)).to eq(%w[09:00 09:10 09:20 09:30])
        expect(starts.size).to eq(16)
      end
    end
  end
end
