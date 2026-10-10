require 'rails_helper'

RSpec.describe Captain::ContextSummary do
  around do |example|
    travel_to(Time.utc(2026, 10, 10, 12)) { example.run }
  end

  def deal(id, **attributes)
    { id: id, contact_id: 10, title: "Deal #{id}", created_at: 10.days.ago.iso8601, updated_at: 1.day.ago.iso8601 }.merge(attributes)
  end

  def appointment(id, start:, **attributes)
    { id: id, contact_id: 10, starts_at: start.iso8601, ends_at: (start + 30.minutes).iso8601, status: 'scheduled' }.merge(attributes)
  end

  it 'shows 9 of 300 for five active and 295 historical deals without redistributing slots' do
    records = (1..5).map { |id| deal(id) } + (6..300).map { |id| deal(id, closed_at: 2.days.ago.iso8601) }
    summary = described_class.from_snapshots(kind: 'deals', records: records, contact_id: 10) { |record| described_class.deal_card(record) }

    expect(summary).to include(shown: 9, total: 300, display: 'Показано 9 из 300', counts: { 'active' => 5, 'history' => 295 })
    expect(summary[:groups].map { |group| [group[:key], group[:shown], group[:total], group[:limit]] })
      .to eq([['active', 5, 5, 8], ['history', 4, 295, 4]])
    expect(summary[:selection]).to include(current_record: nil, redistribute: false, max_rows: 12)
    expect(summary).not_to include(:id, :title)
  end

  it 'sorts history by actual close/archive time and labels missing event times explicitly' do
    records = [
      deal(1, closed_at: 8.days.ago.iso8601, updated_at: Time.current.iso8601),
      deal(2, archived_at: 1.day.ago.iso8601, closed_at: 3.days.ago.iso8601),
      deal(3, stage_outcome: 'won', created_at: 2.days.ago.iso8601)
    ]
    summary = described_class.from_snapshots(kind: 'deals', records: records, contact_id: 10) { |record| described_class.deal_card(record) }
    history = summary[:groups].last[:items]

    expect(history.pluck(:id)).to eq([2, 3, 1])
    expect(history.first[:history_at_source]).to eq('archived_at')
    expect(history.second).to include(history_at_source: 'created_at_fallback_event_time_unknown')
    expect(history.second).not_to include(:closed_at, :archived_at)
  end

  it 'orders ongoing, future, finished and planned cancellations within fixed groups' do
    records = (1..7).map { |id| appointment(id, start: id.days.from_now) }
    records += [appointment(20, start: 10.minutes.ago), appointment(21, start: 1.day.ago),
                appointment(22, start: 2.days.ago), appointment(23, start: 3.days.ago), appointment(24, start: 4.days.ago)]
    records += (30..34).map { |id| appointment(id, start: (id - 29).days.from_now, status: 'cancelled', updated_at: Time.current.iso8601) }
    summary = described_class.from_snapshots(kind: 'appointments', records: records, contact_id: 10) { |record| record.slice(:id, :status) }

    expect(summary).to include(shown: 12, total: 17, counts: { 'upcoming' => 8, 'past' => 4, 'cancelled' => 5 })
    expect(summary[:groups].map { |group| group[:items].pluck(:id) }).to eq([[20, 1, 2, 3, 4, 5], [21, 22, 23], [34, 33, 32]])
    expect(summary[:groups].last[:sort]).to include('planned starts_at DESC')
  end

  it 'does not expand summaries to another patient with the same communication contact' do
    records = [appointment(1, start: 1.hour.from_now, patient_contact_id: 11), appointment(2, start: 1.hour.from_now, contact_id: 11)]
    summary = described_class.from_snapshots(kind: 'appointments', records: records, contact_id: 10) { |record| record.slice(:id) }

    expect(summary).to include(total: 0, shown: 0, display: 'Показано 0 из 0')
    expect(summary[:groups]).to all(include(total: 0, shown: 0, items: []))
  end
end
