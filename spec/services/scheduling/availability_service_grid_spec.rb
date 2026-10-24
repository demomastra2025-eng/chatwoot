require 'rails_helper'

# The starts a specialist offers sit on the grid of their cells (see Scheduling::SlotGrid), not on a five-minute step.
RSpec.describe Scheduling::AvailabilityService do
  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:tuesday) { Date.new(2026, 4, 21) }
  let(:appointments) { [] }
  let(:reception_time) { 10 }
  let(:grid_override) { nil }
  # The detector has settled the grid of the specialist (slot_grid_checked_at): only then is a start off it refused.
  let(:verified) { true }
  let(:resource) do
    attributes = { 'medelement_specialist_code' => 'sp-1', 'medelement_reception_time' => reception_time }
    attributes['slot_grid_min'] = grid_override if grid_override
    attributes['slot_grid_checked_at'] = '2026-04-20T00:00:00Z' if verified
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: reception_time, custom_attributes: attributes)
  end

  def local(hour, minute = 0, date: tuesday)
    zone.local(date.year, date.month, date.day, hour, minute)
  end

  # The cells the provider gives: one working row per reception-time cell.
  def cells(from, to, size: reception_time)
    (from.to_i...to.to_i).step(size * 60).map { |start| [zone.at(start), zone.at(start + (size * 60))] }
  end

  def provider_service(windows, resource: self.resource)
    described_class.new(
      resource: resource, from: local(0), to: local(0) + 1.day, holidays: [], workday_overrides: [], time_offs: [],
      appointments: appointments, provider_working_windows: windows, replace_work_rules: true
    )
  end

  def starts(service, duration_min)
    service.slots(duration_min: duration_min).map { |slot| Time.iso8601(slot[:starts_at]).in_time_zone(zone).strftime('%H:%M') }
  end

  describe 'a specialist with 10-minute cells' do
    let(:service) { provider_service(cells(local(14, 20), local(20))) }

    it 'offers the starts 14:20, 14:30 ... for a 20-minute visit and never 14:25' do
      result = starts(service, 20)

      expect(result.first(4)).to eq(%w[14:20 14:30 14:40 14:50])
      expect(result).not_to include('14:25')
      expect(result.map { |time| time[-1] }.uniq).to eq(['0'])
      expect(result.size).to eq(33)
      expect(result.last).to eq('19:40')
    end

    it 'gives each slot the length of the visit' do
      slot = service.slots(duration_min: 20).first

      expect(Time.iso8601(slot[:ends_at]) - Time.iso8601(slot[:starts_at])).to eq(20.minutes)
    end

    it 'keeps the grid when the free time begins mid-cell after a visit that ended off the grid' do
      appointments << create(:scheduling_appointment, account: account, resource: resource, starts_at: local(14, 20), ends_at: local(14, 45))

      expect(starts(service, 20).first(3)).to eq(%w[14:50 15:00 15:10])
    end

    it 'keeps the grid when the search starts mid-cell' do
      service = described_class.new(
        resource: resource, from: local(14, 25), to: local(16), holidays: [], workday_overrides: [], time_offs: [],
        appointments: [], provider_working_windows: cells(local(14, 20), local(20)), replace_work_rules: true
      )

      expect(starts(service, 20).first(2)).to eq(%w[14:30 14:40])
    end
  end

  describe 'a specialist with 30-minute cells' do
    let(:reception_time) { 30 }
    let(:windows) { cells(local(9), local(12)) }

    it 'offers one start per cell' do
      expect(starts(provider_service(windows), 30)).to eq(%w[09:00 09:30 10:00 10:30 11:00 11:30])
    end

    context 'with slot_grid_min 10' do
      let(:grid_override) { 10 }

      it 'offers 10-minute starts inside the cells' do
        result = starts(provider_service(windows), 30)

        expect(result.first(4)).to eq(%w[09:00 09:10 09:20 09:30])
        expect(result.size).to eq(16)
        expect(result.last).to eq('11:30')
      end

      it 'does not offer a start that is not on the finer grid' do
        expect(starts(provider_service(windows), 30)).not_to include('09:05', '09:15')
      end
    end

    it 'offers no start whose visit would run into a booked cell' do
      appointments << create(:scheduling_appointment, account: account, resource: resource, starts_at: local(9, 30), ends_at: local(10))

      # 09:00 would need the cell of 09:30, 09:30 is taken: the visit of 45 minutes starts from 10:00 on
      expect(starts(provider_service(windows), 45)).to eq(%w[10:00 10:30 11:00])
    end

    it 'skips the cell a longer visit runs into' do
      appointments << create(:scheduling_appointment, account: account, resource: resource, starts_at: local(9), ends_at: local(9, 45))

      # 09:45 is no cell start: the next start is the cell that begins at 10:00
      expect(starts(provider_service(windows), 45)).to eq(%w[10:00 10:30 11:00])
    end
  end

  describe 'a specialist without MedElement hours' do
    let(:resource) do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 20).tap do |item|
        create(:scheduling_work_rule, resource: item, account: account, weekday: tuesday.wday, start_minute: 9 * 60, end_minute: 11 * 60)
      end
    end

    def local_service
      described_class.new(resource: resource, from: local(0), to: local(0) + 1.day, holidays: [], workday_overrides: [],
                          time_offs: [], appointments: appointments)
    end

    it 'steps by slot_duration_min from the start of the work rule' do
      expect(starts(local_service, 20)).to eq(%w[09:00 09:20 09:40 10:00 10:20 10:40])
    end

    it 'keeps the grid across a break' do
      create(:scheduling_break_rule, resource: resource, account: account, weekday: tuesday.wday, start_minute: 10 * 60,
                                     end_minute: (10 * 60) + 20)

      expect(starts(local_service, 20)).to eq(%w[09:00 09:20 09:40 10:20 10:40])
    end

    it 'is not refused for a start off the grid' do
      result = local_service.availability_result(starts_at: local(9, 5), ends_at: local(9, 25), enforce_grid: true)

      expect(result.available?).to be(true)
    end
  end

  describe 'refusing a start off the grid' do
    let(:service) { provider_service(cells(local(14, 20), local(20))) }

    it 'refuses 14:25 and names the starts next to it' do
      result = service.availability_result(starts_at: local(14, 25), ends_at: local(14, 45), enforce_grid: true)

      expect(result.available?).to be(false)
      expect(result.code).to eq('START_OFF_GRID')
      expect(result.status).to eq(:unprocessable_content)
      expect(result.message).to include('14:25', '10 minutes', '14:20 or 14:30')
      expect(result.details).to include(step_min: 10, nearest_starts: [local(14, 20).iso8601, local(14, 30).iso8601])
    end

    it 'accepts the cell starts' do
      [[14, 20], [14, 30], [19, 40]].each do |hour, minute|
        result = service.availability_result(starts_at: local(hour, minute), ends_at: local(hour, minute) + 20.minutes, enforce_grid: true)

        expect(result.available?).to be(true)
      end
    end

    it 'checks the grid only when asked, so a visit that keeps its start can still be extended' do
      result = service.availability_result(starts_at: local(14, 25), ends_at: local(14, 45))

      expect(result.available?).to be(true)
    end

    it 'answers outside working hours before the grid' do
      result = service.availability_result(starts_at: local(13, 5), ends_at: local(13, 25), enforce_grid: true)

      expect(result.code).to eq('OUTSIDE_WORKING_HOURS')
    end

    it 'answers a taken time with a conflict, not a grid error' do
      appointments << create(:scheduling_appointment, account: account, resource: resource, starts_at: local(15), ends_at: local(15, 30))

      result = service.availability_result(starts_at: local(15, 10), ends_at: local(15, 30), enforce_grid: true)

      expect(result.code).to eq('SLOT_CONFLICT')
      expect(result.status).to eq(:conflict)
    end

    context 'with a finer slot_grid_min on 30-minute cells' do
      let(:reception_time) { 30 }
      let(:grid_override) { 10 }

      it 'accepts the 10-minute starts and refuses the others' do
        service = provider_service(cells(local(9), local(12)))
        ok = service.availability_result(starts_at: local(9, 10), ends_at: local(9, 40), enforce_grid: true)
        off = service.availability_result(starts_at: local(9, 15), ends_at: local(9, 45), enforce_grid: true)

        expect(ok.available?).to be(true)
        expect(off.code).to eq('START_OFF_GRID')
      end
    end
  end

  describe 'a specialist whose grid is not verified yet' do
    let(:verified) { false }
    let(:reception_time) { 30 }
    let(:service) { provider_service(cells(local(9), local(12))) }

    def check(hour, minute)
      service.availability_result(starts_at: local(hour, minute), ends_at: local(hour, minute) + 30.minutes, enforce_grid: true)
    end

    it 'does not refuse a start inside a cell, as a doctor booked on 10-minute boundaries is booked' do
      [[9, 10], [9, 20], [10, 40], [11, 5]].each do |hour, minute|
        expect(check(hour, minute).available?).to be(true)
      end
    end

    it 'still offers the cell starts only' do
      expect(starts(service, 30)).to eq(%w[09:00 09:30 10:00 10:30 11:00 11:30])
    end

    it 'still answers a taken time and a time outside the hours' do
      appointments << create(:scheduling_appointment, account: account, resource: resource, starts_at: local(9, 30), ends_at: local(10))

      expect(check(9, 40).code).to eq('SLOT_CONFLICT')
      expect(check(12, 10).code).to eq('OUTSIDE_WORKING_HOURS')
    end

    context 'when slot_grid_min settles the grid at the reception time' do
      let(:grid_override) { 30 }

      it 'refuses a start off the cells' do
        expect(check(9, 10).code).to eq('START_OFF_GRID')
        expect(check(9, 30).available?).to be(true)
      end
    end

    context 'when slot_grid_min is a finer step' do
      let(:grid_override) { 10 }

      it 'refuses a start off the finer grid' do
        expect(check(9, 10).available?).to be(true)
        expect(check(9, 15).code).to eq('START_OFF_GRID')
      end
    end

    context 'when slot_grid_min is not a usable step' do
      let(:grid_override) { 7 }

      it 'does not count as a verdict' do
        expect(check(9, 10).available?).to be(true)
      end
    end
  end
end
