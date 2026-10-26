require 'rails_helper'

RSpec.describe Captain::Tools::Agent::SlotsPayload do
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:monday) { Date.new(2026, 4, 20) }

  # options: name, duration_min
  def slot(resource_id, date, hour, minute = 0, **options)
    starts_at = zone.local(date.year, date.month, date.day, hour, minute)
    duration_min = options.fetch(:duration_min, 30)
    { resource_id: resource_id, resource_name: options.fetch(:name, "Doctor #{resource_id}"), timezone: 'Asia/Almaty',
      duration_min: duration_min, status: 'available', starts_at: starts_at.iso8601,
      ends_at: (starts_at + duration_min.minutes).iso8601, availability_source: 'medelement', medelement_cabinet_code: 'cab-1' }
  end

  # Every start of a day from `from` to `to` (not including `to`), in steps of `step` minutes.
  def day(resource_id, date, from: 9, to: 18, **options)
    ((from * 60)...(to * 60)).step(options.fetch(:step, 30)).map do |minute|
      slot(resource_id, date, minute / 60, minute % 60, **options.except(:step))
    end
  end

  def clock(minute)
    format('%<hour>02d:%<minute>02d', hour: minute / 60, minute: minute % 60)
  end

  describe '.spread' do
    it 'returns all the minutes when there are not more than the count' do
      expect(described_class.spread([540, 570, 600])).to eq([540, 570, 600])
    end

    it 'takes the first and the last and spreads the rest, not neighbouring starts' do
      minutes = ((9 * 60)...(18 * 60)).step(30).to_a

      expect(described_class.spread(minutes).map { |minute| clock(minute) }).to eq(%w[09:00 11:00 13:00 15:00 17:30])
    end

    it 'follows the free time when it has gaps' do
      minutes = [540, 550, 560, 1000, 1010, 1020, 1030]

      picked = described_class.spread(minutes)

      expect(picked.size).to eq(5)
      expect(picked).to include(540, 1030)
      expect(picked.count { |minute| minute >= 720 }).to be >= 2
    end
  end

  describe '.day_entries' do
    it 'makes one entry per specialist and day with at most five times and counts the rest' do
      entries = described_class.day_entries(day(7, monday, from: 9, to: 19, step: 10, name: 'Aigerim'))

      expect(entries.size).to eq(1)
      expect(entries.first).to include(resource_id: 7, name: 'Aigerim', date: '2026-04-20', more: 55)
      expect(entries.first[:times].size).to eq(5)
      expect(entries.first[:times].first).to eq('09:00')
      expect(entries.first[:times].last).to eq('18:50')
    end

    it 'includes the afternoon when a day has afternoon starts' do
      times = described_class.day_entries(day(7, monday, from: 9, to: 19, step: 10)).first[:times]

      expect(times.count { |time| time >= '12:00' }).to be >= 2
    end

    it 'lists a day with five or fewer starts in full' do
      entry = described_class.day_entries([slot(7, monday, 9), slot(7, monday, 9, 30), slot(7, monday, 14)]).first

      expect(entry).to include(times: %w[09:00 09:30 14:00], more: 0)
    end

    it 'groups by specialist and by local day and orders them by day, then specialist' do
      slots = day(8, monday + 1, from: 9, to: 10) + day(7, monday + 1, from: 9, to: 10) + day(8, monday, from: 9, to: 10)

      entries = described_class.day_entries(slots)

      expect(entries.map { |entry| entry.values_at(:date, :resource_id) }).to eq([['2026-04-20', 8], ['2026-04-21', 7], ['2026-04-21', 8]])
    end

    it 'reads the day and the time on the specialist clock, not in UTC' do
      # 02:00 in Almaty is 21:00 UTC of the day before
      entries = described_class.day_entries([slot(7, monday, 2, 0), slot(7, monday, 23, 30)])

      expect(entries.map { |item| item.values_at(:date, :times) }).to eq([['2026-04-20', %w[02:00 23:30]]])
    end

    it 'counts a start that two cabinets give once' do
      entry = described_class.day_entries([slot(7, monday, 9), slot(7, monday, 9)]).first

      expect(entry).to include(times: ['09:00'], more: 0)
    end
  end

  describe '.answer' do
    let(:payload) do
      { requested_service_id: 12, duration_min: 30, slots: day(7, monday, from: 9, to: 19, step: 10), total_slots: 60,
        service: { id: 12, name: 'Consultation' }, resources: [{ id: 7 }], availability: { status: 'fresh' } }
    end

    it 'says the service and the duration once at the top and drops the cards' do
      answer = described_class.answer(payload)

      expect(answer).to include(service_id: 12, duration_min: 30, total: 60)
      expect(answer.keys).to eq(%i[service_id duration_min total days])
      expect(answer[:days].first.keys).to eq(%i[resource_id name date times more])
    end

    it 'lists the first specialist-days up to the limit and counts the others' do
      slots = (0..4).flat_map { |offset| day(7, monday + offset, from: 9, to: 10) }

      answer = described_class.answer({ slots: slots }, days_limit: 2)

      expect(answer[:days].pluck(:date)).to eq(%w[2026-04-20 2026-04-21])
      expect(answer[:more_days]).to eq(3)
      expect(described_class.answer({ slots: slots }, days_limit: 99)[:days].size).to eq(5)
    end

    it 'lists ten specialist-days without a limit' do
      slots = (0..14).flat_map { |offset| day(7, monday + offset, from: 9, to: 10) }

      expect(described_class.answer({ slots: slots })[:days].size).to eq(10)
    end

    it 'keeps the length of each entry when the specialists have different visit lengths' do
      slots = day(7, monday, from: 9, to: 10, duration_min: 30) + day(8, monday, from: 9, to: 10, duration_min: 45)

      answer = described_class.answer({ slots: slots, duration_min: 30 })

      expect(answer).not_to have_key(:duration_min)
      expect(answer[:days].pluck(:duration_min)).to eq([30, 45])
    end

    it 'answers an empty range with a total of zero and no days' do
      expect(described_class.answer({ slots: [], requested_service_id: 12, duration_min: 30 }))
        .to eq(service_id: 12, duration_min: 30, total: 0, days: [])
    end

    it 'tells the agent that an unchecked schedule is not an empty one' do
      answer = described_class.answer({ slots: [], availability: { status: 'degraded' } })

      expect(answer).to include(availability: 'degraded', availability_note: include('Do not tell the patient that there is none'))
    end

    # Suggestion eval 26.10: Intermedical 113 handed catalog prices to staff because the schedule was not confirmed.
    it 'tells the agent that a price does not depend on an unchecked schedule' do
      answer = described_class.answer({ slots: [], availability: { status: 'degraded' } })

      expect(answer[:availability_note]).to include('A price from search_scheduling_services does not depend on the schedule: give it.')
    end
  end

  describe '.next_available' do
    let(:slots) { day(7, monday + 1, from: 9, to: 18) + day(7, monday + 2, from: 9, to: 18) + day(8, monday + 2, from: 9, to: 18) }

    it 'lists the nearest specialist-days' do
      days = described_class.next_available(slots + day(7, monday + 3, from: 9, to: 10), days: 3)

      expect(days.map { |entry| entry.values_at(:date, :resource_id) }).to eq([['2026-04-21', 7], ['2026-04-22', 7], ['2026-04-22', 8]])
      expect(days.first.keys).to eq(%i[resource_id name date times more])
    end

    it 'shows the afternoon starts to a patient who asked for the afternoon' do
      days = described_class.next_available(slots, requested_from: zone.local(2026, 4, 20, 14))

      expect(days.flat_map { |entry| entry[:times] }.min).to be >= '14:00'
    end

    it 'falls back to all the starts when none is that late' do
      days = described_class.next_available(day(7, monday + 1, from: 9, to: 12), requested_from: zone.local(2026, 4, 20, 15))

      expect(days.first[:times].first).to eq('09:00')
    end
  end
end
