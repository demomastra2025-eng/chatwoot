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

  def stored_day(status: 'confirmed', checked_at: Time.current, windows: [{ start_minute: 10 * 60, end_minute: 11 * 60 }])
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1',
      date: date, status: status, source_checked_at: checked_at, windows: windows
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

  it 'does not offer days outside the MedElement horizon' do
    later = zone.local(2026, 7, 19, 9)
    availability = described_class.new(resource: resource, from: later, to: later + 1.hour).perform
    expect(availability.state).to eq('beyond_horizon')
    expect(availability.last_bookable_date).to eq(Date.new(2026, 7, 18))
    expect(availability.slots).to be_empty
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
