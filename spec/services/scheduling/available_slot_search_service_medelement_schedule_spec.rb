require 'rails_helper'

RSpec.describe Scheduling::AvailableSlotSearchService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'specialist-1',
                                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                                 })
  end

  before do
    account.enable_features!('scheduling')
    hook
    Integrations::Medelement::SpecialistWorkRulesSyncService.new(account: account).perform(resource)
  end

  def day(date, status: 'confirmed', start_minute: 15 * 60, end_minute: 17 * 60, checked_at: Time.current)
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1', date: date,
      status: status, source_checked_at: checked_at,
      windows: status == 'confirmed' ? [{ start_minute: start_minute, end_minute: end_minute }] : []
    )
  end

  def search(date, limit: 50)
    described_class.new(account: account, resource_ids: [resource.id],
                        from: zone.local(date.year, date.month, date.day, 9),
                        to: zone.local(date.year, date.month, date.day, 18),
                        duration_min: 30, limit: limit).perform
  end

  it 'finds afternoon windows from the table without requesting the provider' do
    day(Date.new(2026, 4, 20))
    expect(Integrations::Medelement::Client).not_to receive(:new)

    payload = search(Date.new(2026, 4, 20))

    expect(payload[:availability][:status]).to eq('fresh')
    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
    expect(payload[:slots].first[:medelement_cabinet_code]).to eq('cabinet-1')
  end

  it 'uses provider hours on Sunday despite local rules, holiday, vacation and break' do
    date = Date.new(2026, 4, 26)
    day(date, start_minute: 10 * 60, end_minute: 12 * 60)
    create(:scheduling_holiday, account: account, date: date)
    create(:scheduling_time_off, account: account, resource: resource,
                                 starts_at: zone.local(2026, 4, 26, 10), ends_at: zone.local(2026, 4, 26, 11))
    expect(search(date)[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 26, 10).iso8601)
  end

  it 'subtracts local and imported appointments, including completed visits' do
    date = Date.new(2026, 4, 20)
    day(date)
    create(:scheduling_appointment, account: account, resource: resource,
                                    starts_at: zone.local(2026, 4, 20, 15), ends_at: zone.local(2026, 4, 20, 15, 30))
    create(:scheduling_appointment, account: account, resource: resource, source: 'medelement', status: 'completed',
                                    starts_at: zone.local(2026, 4, 20, 15, 30), ends_at: zone.local(2026, 4, 20, 16))

    expect(search(date)[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 16).iso8601)
  end

  it 'does not offer an unconfirmed, missing or stale day' do
    date = Date.new(2026, 4, 20)
    day(date, status: 'empty_unconfirmed')
    expect(search(date)[:slots]).to be_empty
    expect(search(date)[:availability][:status]).to eq('degraded')

    missing_date = date + 1
    expect(search(missing_date)[:slots]).to be_empty
    stale_date = date + 2
    day(stale_date, checked_at: 13.hours.ago)
    expect(search(stale_date)[:slots]).to be_empty
  end

  it 'uses confirmed on-demand hours across the background cache boundary' do
    last_date = Date.new(2026, 7, 18)
    day(last_date, start_minute: 10 * 60, end_minute: 12 * 60)
    client = instance_double(Integrations::Medelement::Client, get_receptions: [])
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    payload = (last_date..(last_date + 2)).to_h do |date|
      key = date.strftime('%d.%m.%Y')
      [key, { 'timetable' => [{ 'start' => "#{key} 10:00", 'end' => "#{key} 12:00", 'working' => true }] }]
    end
    allow(client).to receive(:timetable).and_return(payload)

    payload = described_class.new(account: account, resource_ids: [resource.id],
                                  from: zone.local(2026, 7, 18, 9), to: zone.local(2026, 7, 20, 9),
                                  duration_min: 30).perform

    expect(payload[:slots].pluck(:starts_at)).to include(zone.local(2026, 7, 18, 10).iso8601)
    expect(search(Date.new(2026, 7, 19))[:slots].pluck(:starts_at)).to include(zone.local(2026, 7, 19, 10).iso8601)
    expect(payload[:availability][:status]).to eq('fresh')
  end

  it 'does not list an unpublished specialist' do
    resource.update!(active: false, custom_attributes: resource.custom_attributes.merge('medelement_schedule_published' => false))
    expect { search(Date.new(2026, 4, 20)) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
