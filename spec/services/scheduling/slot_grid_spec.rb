require 'rails_helper'

RSpec.describe Scheduling::SlotGrid do
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }

  def resource(slot_duration_min: 30, **attributes)
    Scheduling::Resource.new(slot_duration_min: slot_duration_min, custom_attributes: attributes.stringify_keys)
  end

  def at(hour, minute = 0)
    zone.local(2026, 4, 21, hour, minute)
  end

  def clock(times)
    times.map { |time| time.strftime('%H:%M') }
  end

  describe '.step_minutes' do
    it 'is the reception time of a MedElement specialist, whatever the visit length stored for them' do
      doctor = resource(slot_duration_min: 60, medelement_specialist_code: 'sp-1', medelement_reception_time: 20)

      expect(described_class.step_minutes(doctor)).to eq(20)
    end

    it 'reads the reception time as the provider sends it (a string or a whole float)' do
      expect(described_class.step_minutes(resource(medelement_specialist_code: 'sp-1', medelement_reception_time: '15'))).to eq(15)
      expect(described_class.step_minutes(resource(medelement_specialist_code: 'sp-1', medelement_reception_time: 10.0))).to eq(10)
    end

    it 'falls back to slot_duration_min when the provider sent no reception time' do
      expect(described_class.step_minutes(resource(slot_duration_min: 15, medelement_specialist_code: 'sp-1'))).to eq(15)
      expect(described_class.step_minutes(resource(slot_duration_min: 45, medelement_specialist_code: 'sp-1',
                                                   medelement_reception_time: 'soon'))).to eq(45)
    end

    it 'is slot_duration_min for a local specialist, who has no reception time' do
      expect(described_class.step_minutes(resource(slot_duration_min: 20, medelement_reception_time: 10))).to eq(20)
    end

    it 'takes a finer slot_grid_min that divides the reception time' do
      doctor = resource(medelement_specialist_code: 'sp-1', medelement_reception_time: 30, slot_grid_min: 10)

      expect(described_class.step_minutes(doctor)).to eq(10)
      expect(described_class.base_step_minutes(doctor)).to eq(30)
    end

    it 'ignores a slot_grid_min that is not a finer divisor of the reception time' do
      [15, 45, 30, 3, 0, -10, 'ten', nil].each do |value|
        reception = value == 15 ? 20 : 30
        doctor = resource(medelement_specialist_code: 'sp-1', medelement_reception_time: reception, slot_grid_min: value)

        expect(described_class.step_minutes(doctor)).to eq(reception)
      end
    end

    it 'applies the override to a local specialist too' do
      expect(described_class.step_minutes(resource(slot_duration_min: 30, slot_grid_min: 10))).to eq(10)
    end

    it 'never goes under the smallest step' do
      expect(described_class.step_minutes(resource(slot_duration_min: 5))).to eq(5)
    end
  end

  describe '.verified?' do
    def doctor(**attributes)
      resource(medelement_specialist_code: 'sp-1', medelement_reception_time: 30, **attributes)
    end

    it 'is false for a specialist whose grid nobody has settled' do
      expect(described_class.verified?(doctor)).to be(false)
    end

    it 'is true once the detector stored the time of its verdict' do
      expect(described_class.verified?(doctor(slot_grid_checked_at: '2026-04-20T00:00:00Z'))).to be(true)
    end

    it 'is true for a finer slot_grid_min and for one equal to the reception time' do
      expect(described_class.verified?(doctor(slot_grid_min: 10))).to be(true)
      expect(described_class.verified?(doctor(slot_grid_min: '15'))).to be(true)
      expect(described_class.verified?(doctor(slot_grid_min: 30))).to be(true)
    end

    it 'is false for a slot_grid_min that is no usable step' do
      [7, 45, 0, -10, 'ten', nil, ''].each do |value|
        expect(described_class.verified?(doctor(slot_grid_min: value))).to be(false)
      end
    end

    it 'is false when only an empty verdict time is stored' do
      expect(described_class.verified?(doctor(slot_grid_checked_at: ''))).to be(false)
    end
  end

  describe '.starts' do
    let(:cell_minutes) { 10 }
    let(:cells) { (at(14, 20).to_i...at(20).to_i).step(cell_minutes * 60).map { |from| [zone.at(from), zone.at(from + (cell_minutes * 60))] } }
    let(:day) { [at(14, 20), at(20)] }

    it 'steps from the cell starts, never by five minutes from the interval start' do
      starts = described_class.starts(cells: cells, interval: day, step_minutes: 10, duration: 20.minutes)

      expect(clock(starts).first(3)).to eq(%w[14:20 14:30 14:40])
      expect(clock(starts)).not_to include('14:25')
      expect(starts.size).to eq(33)
      expect(clock(starts).last).to eq('19:40')
    end

    it 'begins a free interval that starts mid-cell at the next grid start' do
      starts = described_class.starts(cells: cells, interval: [at(14, 45), at(15, 30)], step_minutes: 10, duration: 20.minutes)

      expect(clock(starts)).to eq(%w[14:50 15:00 15:10])
    end

    it 'cuts a 30-minute cell by a finer step and keeps the cell starts' do
      cell = [[at(9), at(9, 30)], [at(9, 30), at(10)]]

      expect(clock(described_class.starts(cells: cell, interval: [at(9), at(10)], step_minutes: 10, duration: 10.minutes)))
        .to eq(%w[09:00 09:10 09:20 09:30 09:40 09:50])
      expect(clock(described_class.starts(cells: cell, interval: [at(9), at(10)], step_minutes: 30, duration: 10.minutes)))
        .to eq(%w[09:00 09:30])
    end

    it 'needs room for the whole visit, over several cells when the visit is longer than a cell' do
      cell = [[at(9), at(9, 30)], [at(9, 30), at(10)], [at(10), at(10, 30)]]

      expect(clock(described_class.starts(cells: cell, interval: [at(9), at(10, 30)], step_minutes: 30, duration: 45.minutes)))
        .to eq(%w[09:00 09:30])
    end

    it 'does not step past the end of a cell into time that is not a cell' do
      cell = [[at(9), at(9, 30)], [at(10), at(10, 30)]]

      expect(clock(described_class.starts(cells: cell, interval: [at(9), at(10, 30)], step_minutes: 10, duration: 10.minutes)))
        .to eq(%w[09:00 09:10 09:20 10:00 10:10 10:20])
    end
  end

  describe '.on_grid?' do
    let(:cells) { [[at(14, 20), at(14, 50)], [at(14, 50), at(15, 20)]] }

    it 'is true for a cell start and for whole steps after it' do
      expect(described_class.on_grid?(at(14, 20), cells: cells, step_minutes: 10)).to be(true)
      expect(described_class.on_grid?(at(14, 30), cells: cells, step_minutes: 10)).to be(true)
      expect(described_class.on_grid?(at(14, 50), cells: cells, step_minutes: 30)).to be(true)
    end

    it 'is false between the steps, before the first cell and at or after the end of the last one' do
      expect(described_class.on_grid?(at(14, 25), cells: cells, step_minutes: 10)).to be(false)
      expect(described_class.on_grid?(at(14, 30), cells: cells, step_minutes: 30)).to be(false)
      expect(described_class.on_grid?(at(14, 10), cells: cells, step_minutes: 10)).to be(false)
      expect(described_class.on_grid?(at(15, 20), cells: cells, step_minutes: 10)).to be(false)
    end
  end

  describe '.neighbours' do
    it 'returns the grid starts on both sides of a time' do
      cells = [[at(14, 20), at(14, 50)], [at(14, 50), at(15, 20)]]

      previous, following = described_class.neighbours(at(14, 25), cells: cells, step_minutes: 10)

      expect(clock([previous, following])).to eq(%w[14:20 14:30])
    end

    it 'returns nil on a side where the grid has no start' do
      expect(described_class.neighbours(at(9), cells: [[at(9, 10), at(9, 40)]], step_minutes: 10)).to eq([nil, at(9, 10)])
      expect(described_class.neighbours(at(9), cells: [], step_minutes: 10)).to eq([nil, nil])
    end
  end
end
