require 'rails_helper'

RSpec.describe Scheduling::ScheduleDayAvailabilityService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:date) { Date.new(2026, 4, 20) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Europe/Moscow',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'specialist-1',
                                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                                 })
  end
  let(:from) { zone.local(2026, 4, 20, 9) }
  let(:to) { zone.local(2026, 4, 20, 12) }

  before do
    account.enable_features!('scheduling')
    hook
  end

  def stored_day(status: 'confirmed', checked_at: Time.current, windows: [{ start_minute: 10 * 60, end_minute: 11 * 60 }], on: date)
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1',
      date: on, status: status, source_checked_at: checked_at, windows: windows
    )
  end

  def result(**)
    described_class.new(resource: resource, from: from, to: to, duration_min: 30, **).perform
  end

  it 'returns windows from a confirmed day on the provider clock even when the resource clock differs' do
    stored_day
    expect(Integrations::Medelement::Client).not_to receive(:new)

    availability = result

    expect(availability.state).to eq('ok')
    expect(availability.source).to eq('provider_schedule')
    expect(Time.iso8601(availability.slots.first[:starts_at])).to eq(zone.local(2026, 4, 20, 10))
    expect(availability.slots.first[:cabinet_code]).to eq('cabinet-1')
  end

  %w[empty_unconfirmed unverified].each do |status|
    it "does not expose #{status} windows" do
      stored_day(status: status)
      expect(result.slots).to be_empty
      expect(result.state).to eq('schedule_not_confirmed')
    end
  end

  it 'treats a confirmed empty day as closed' do
    stored_day(status: 'empty_confirmed', windows: [])
    expect(result.state).to eq('closed_day')
    expect(result.slots).to be_empty
  end

  it 'does not offer a missing or stale day' do
    expect(result.state).to eq('schedule_not_confirmed')
    stored_day(checked_at: 2.hours.ago)
    expect(result.state).to eq('schedule_not_confirmed')
    expect(result.slots).to be_empty
  end

  it 'restricts windows to the selected cabinet' do
    resource.update!(custom_attributes: resource.custom_attributes.merge(
      'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }, { 'companyCabinetCode' => 'cabinet-2' }]
    ))
    stored_day(windows: [{ 'start_minute' => 600, 'end_minute' => 660, 'cabinet_code' => 'cabinet-2' }])

    expect(result(cabinet_code: 'cabinet-1').slots).to be_empty
    expect(result(cabinet_code: 'cabinet-2').slots.first[:cabinet_code]).to eq('cabinet-2')
  end

  it 'subtracts local and imported receptions while retaining cancelled slots' do
    stored_day
    create(:scheduling_appointment, account: account, resource: resource,
                                    starts_at: zone.local(2026, 4, 20, 10), ends_at: zone.local(2026, 4, 20, 10, 15))
    create(:scheduling_appointment, account: account, resource: resource, source: 'medelement', status: 'no_show',
                                    starts_at: zone.local(2026, 4, 20, 10, 15), ends_at: zone.local(2026, 4, 20, 10, 30))
    create(:scheduling_appointment, account: account, resource: resource, status: 'cancelled',
                                    starts_at: zone.local(2026, 4, 20, 10, 30), ends_at: zone.local(2026, 4, 20, 11))
    expect(Time.iso8601(result.slots.first[:starts_at])).to eq(zone.local(2026, 4, 20, 10, 30))
  end

  it 'uses only fresh confirmed stored windows for a partial past range when live reads are disabled' do
    first_date = Date.new(2026, 4, 15)
    stored_day(on: first_date)
    stored_day(on: first_date + 1, status: 'empty_confirmed', windows: [])
    stored_day(on: first_date + 2, status: 'unverified')
    stored_day(on: first_date + 3, checked_at: 2.hours.ago)
    (first_date...date).each do |day|
      create(:scheduling_work_rule, account: account, resource: resource, weekday: day.wday,
                                    start_minute: 9 * 60, end_minute: 12 * 60)
    end
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
    expect(Integrations::Medelement::Client).not_to receive(:new)

    availability = described_class.new(
      resource: resource, from: zone.local(2026, 4, 15), to: zone.local(2026, 4, 20),
      duration_min: 60, allow_live: false
    ).perform

    expect(availability.state).to eq('schedule_not_confirmed')
    expect(availability.source).to eq('provider_schedule')
    expect(availability.checked_at).to eq(Time.current)
    expect(availability.last_bookable_date).to be_nil
    expect(availability.slots).to contain_exactly(
      include(resource_id: resource.id, cabinet_code: 'cabinet-1', duration_min: 60,
              starts_at: zone.local(2026, 4, 15, 10).in_time_zone(resource.timezone).iso8601,
              ends_at: zone.local(2026, 4, 15, 11).in_time_zone(resource.timezone).iso8601)
    )
  end

  [Date.new(2026, 4, 18), Date.new(2026, 7, 19)].each do |requested_date|
    it "reads a confirmed provider day on demand for #{requested_date}, outside the background cache" do
      client = instance_double(Integrations::Medelement::Client)
      later = zone.local(requested_date.year, requested_date.month, requested_date.day, 9)
      day_key = requested_date.strftime('%d.%m.%Y')
      allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
      allow(client).to receive(:timetable).and_return(
        day_key => { 'timetable' => [{ 'start' => "#{day_key} 09:00", 'end' => "#{day_key} 10:00", 'working' => true }] }
      )
      allow(client).to receive(:get_receptions).and_return([])

      availability = described_class.new(resource: resource, from: later, to: later + 1.hour, duration_min: 45).perform

      expect(availability.state).to eq('ok')
      expect(availability.last_bookable_date).to be_nil
      slot = availability.slots.first
      expect(Time.iso8601(slot.fetch(:starts_at))).to eq(later)
      expect(Time.iso8601(slot.fetch(:ends_at))).to eq(later + 45.minutes)
      expect(slot).to include(duration_min: 45, cabinet_code: 'cabinet-1', availability_source: 'medelement')
      expect(client).to have_received(:timetable).with(
        specialist_code: 'specialist-1', starts_on: requested_date, ends_on: requested_date
      )
    end
  end

  it 'does not replace an unconfirmed on-demand day with local work rules' do
    later = zone.local(2026, 7, 19, 9)
    create(:scheduling_work_rule, account: account, resource: resource, weekday: later.wday,
                                  start_minute: 9 * 60, end_minute: 12 * 60)
    client = instance_double(Integrations::Medelement::Client, timetable: { '19.07.2026' => { 'timetable' => [] } })
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)

    availability = described_class.new(resource: resource, from: later, to: later + 1.hour).perform
    expect(availability.state).to eq('schedule_not_confirmed')
    expect(availability.last_bookable_date).to be_nil
    expect(availability.slots).to be_empty
  end

  it 'reuses an already confirmed later day without extra provider HTTP' do
    later = zone.local(2026, 7, 19, 9)
    stored_day.update!(date: Date.new(2026, 7, 19), windows: [{ start_minute: 540, end_minute: 600 }])
    expect(Integrations::Medelement::Client).not_to receive(:new)

    availability = described_class.new(resource: resource, from: later, to: later + 1.hour).perform

    expect(availability.state).to eq('ok')
    expect(availability.slots).to be_present
  end

  it 'keeps local scheduling rules for non-integrated resources' do
    local = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, account: account, resource: local, weekday: 1,
                                  start_minute: 9 * 60, end_minute: 12 * 60)
    availability = described_class.new(resource: local, from: from, to: to, duration_min: 30).perform
    expect(availability.source).to eq('local_rules')
    expect(availability.slots.first[:starts_at]).to eq(from.iso8601)
  end
end
