require 'rails_helper'

RSpec.describe Scheduling::SlotGridDetector do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 20, 6)) { example.run } }

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:contact) { create(:contact, account: account) }
  let(:attributes) { { 'medelement_specialist_code' => 'sp-1', 'medelement_reception_time' => 30 } }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30, custom_attributes: attributes)
  end

  # Imported receptions: every listed clock time on each of the days before today.
  def import(clocks, days: 10, source: 'medelement', status: 'scheduled')
    (1..days).each do |ago|
      date = Time.current.in_time_zone(zone).to_date - ago
      clocks.each do |hour, minute|
        starts_at = zone.local(date.year, date.month, date.day, hour, minute)
        create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: nil, source: source,
                                        status: status, starts_at: starts_at, ends_at: starts_at + 10.minutes)
      end
    end
  end

  def detect
    described_class.new(resource: resource).perform
  end

  it 'finds a finer step when most starts sit on 10-minute boundaries inside 30-minute cells' do
    import([[9, 0], [9, 10], [9, 40]])

    result = detect

    expect(result).to have_attributes(status: 'finer', reception_min: 30, step_min: 10, share: 1.0, starts: 30)
  end

  it 'picks the coarsest finer step that holds the starts' do
    import([[9, 0], [9, 15], [9, 45]])

    expect(detect).to have_attributes(status: 'finer', step_min: 15)
  end

  it 'calls the grid regular when 95% of the starts sit on it, so a stray start does not make it finer' do
    import([[9, 0], [9, 30], [10, 0]], days: 19)
    import([[9, 10]], days: 1)

    # 57 of the 58 starts share the remainder of their day (98%)
    expect(detect).to have_attributes(status: 'on_grid', step_min: nil, starts: 58)
  end

  it 'does not read the clock minute: a day anchored at 14:20 is on a 30-minute grid' do
    import([[14, 20], [14, 50], [15, 20]])

    expect(detect).to have_attributes(status: 'on_grid', share: 1.0)
  end

  it 'reports an irregular grid when no step of five minutes holds the starts' do
    import([[9, 0], [9, 7]])

    expect(detect).to have_attributes(status: 'irregular', step_min: nil)
  end

  it 'asks for more data when there are too few starts' do
    import([[9, 0], [9, 10]], days: 3)

    expect(detect).to have_attributes(status: 'insufficient', starts: 6)
  end

  it 'leaves out a day with a single start' do
    import([[9, 10]])

    expect(detect).to have_attributes(status: 'insufficient', starts: 0)
  end

  it 'reads only imported, kept receptions of the last 60 days' do
    import([[9, 0], [9, 10], [9, 40]], source: 'manual')
    import([[9, 0], [9, 10], [9, 40]], status: 'cancelled')
    import([[9, 0], [9, 30]], days: 5)
    old = Time.current.in_time_zone(zone) - 70.days
    2.times do |index|
      create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: nil, source: 'medelement',
                                      starts_at: old + (index * 10).minutes, ends_at: old + ((index * 10) + 10).minutes)
    end

    expect(detect).to have_attributes(status: 'insufficient', starts: 10)
  end

  describe '.run and #apply!' do
    let(:scope) { Scheduling::Resource.where(account_id: account.id) }

    before { import([[9, 0], [9, 10], [9, 40]]) }

    it 'only reports on a dry run' do
      results = described_class.run(scope: scope)

      expect(results.map(&:step_min)).to eq([10])
      expect(resource.reload.custom_attributes).not_to have_key('slot_grid_min')
    end

    it 'stores the finer step and keeps the other attributes' do
      described_class.run(scope: scope, apply: true)

      expect(resource.reload.custom_attributes).to include('slot_grid_min' => 10, 'medelement_reception_time' => 30)
      expect(Scheduling::SlotGrid.step_minutes(resource)).to eq(10)
    end

    it 'leaves the grid unverified on a dry run and verifies it on apply' do
      described_class.run(scope: scope)

      expect(resource.reload.custom_attributes).not_to have_key('slot_grid_checked_at')
      expect(Scheduling::SlotGrid.verified?(resource)).to be(false)

      described_class.run(scope: scope, apply: true)

      expect(resource.reload.custom_attributes).to include('slot_grid_checked_at' => Time.current.utc.iso8601)
      expect(Scheduling::SlotGrid.verified?(resource)).to be(true)
    end

    it 'verifies a doctor whose starts sit on the cells, without storing a step' do
      Scheduling::Appointment.where(resource_id: resource.id).delete_all
      import([[9, 0], [9, 30], [10, 0]])

      described_class.run(scope: scope, apply: true)

      expect(resource.reload.custom_attributes).to include('slot_grid_checked_at' => Time.current.utc.iso8601)
      expect(resource.custom_attributes).not_to have_key('slot_grid_min')
      expect(Scheduling::SlotGrid.verified?(resource)).to be(true)
    end

    it 'writes nothing on a second run with the same verdict' do
      described_class.run(scope: scope, apply: true)
      stored = resource.reload.custom_attributes

      described_class.run(scope: scope, apply: true, now: 1.hour.from_now)

      expect(resource.reload.custom_attributes).to eq(stored)
    end

    it 'leaves a doctor unverified when the starts are irregular or too few to decide' do
      Scheduling::Appointment.where(resource_id: resource.id).delete_all
      import([[9, 0], [9, 7]])
      irregular = resource

      few = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30,
                                         custom_attributes: attributes.merge('medelement_specialist_code' => 'sp-2'))

      described_class.run(scope: scope, apply: true)

      expect(irregular.reload.custom_attributes).not_to have_key('slot_grid_checked_at')
      expect(few.reload.custom_attributes).not_to have_key('slot_grid_checked_at')
      expect(Scheduling::SlotGrid.verified?(irregular)).to be(false)
      expect(Scheduling::SlotGrid.verified?(few)).to be(false)
    end

    it 'removes a stored step when the reception time holds the starts' do
      resource.update!(custom_attributes: attributes.merge('slot_grid_min' => 10))
      Scheduling::Appointment.where(resource_id: resource.id).delete_all
      import([[9, 0], [9, 30], [10, 0]])

      described_class.run(scope: scope, apply: true)

      expect(resource.reload.custom_attributes).not_to have_key('slot_grid_min')
      expect(Scheduling::SlotGrid.verified?(resource)).to be(true)
    end

    it 'keeps a stored step when the data is not enough to decide' do
      resource.update!(custom_attributes: attributes.merge('slot_grid_min' => 10))
      Scheduling::Appointment.where(resource_id: resource.id).delete_all

      described_class.run(scope: scope, apply: true)

      expect(resource.reload.custom_attributes).to include('slot_grid_min' => 10)
    end

    it 'skips a specialist that has no MedElement hours' do
      create(:scheduling_resource, account: account)

      expect(described_class.run(scope: scope).map(&:resource_id)).to eq([resource.id])
    end
  end
end
