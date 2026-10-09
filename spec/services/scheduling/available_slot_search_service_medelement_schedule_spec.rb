require 'rails_helper'

RSpec.describe Scheduling::AvailableSlotSearchService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'specialist-1',
                                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                                 })
  end

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    Integrations::Medelement::SpecialistWorkRulesSyncService.new(account: account).perform(resource)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_receptions).and_return([])
  end

  def search(date, limit: 50)
    described_class.new(account: account, resource_ids: [resource.id],
                        from: zone.local(date.year, date.month, date.day, 9),
                        to: zone.local(date.year, date.month, date.day, 18),
                        duration_min: 30, limit: limit).perform
  end

  def provider_day(date, from_hour:, to_hour:)
    formatted_date = date.strftime('%d.%m.%Y')
    { formatted_date => {
      'timetable' => [{ 'start' => "#{formatted_date} #{from_hour}:00",
                        'end' => "#{formatted_date} #{to_hour}:00", 'working' => true }]
    } }
  end

  it 'finds afternoon slots after the first 50 template candidates' do
    date = Date.new(2026, 4, 20)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))

    payload = search(date)

    expect(payload[:availability][:status]).to eq('fresh')
    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
    expect(client).to have_received(:timetable).once
    expect(client).to have_received(:get_receptions).once
  end

  it 'finds Sunday slots when the unmodified OneLink template is closed' do
    date = Date.new(2026, 4, 26)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 10, to_hour: 12))

    payload = search(date)

    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 26, 10).iso8601)
    expect(payload[:availability][:status]).to eq('fresh')
  end

  it 'uses provider hours when the local schedule is empty' do
    resource.work_rules.destroy_all
    date = Date.new(2026, 4, 20)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))

    payload = search(date)

    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
    expect(payload[:availability][:status]).to eq('fresh')
  end

  it 'ignores a local break for a provider specialist' do
    date = Date.new(2026, 4, 20)
    create(:scheduling_break_rule, resource: resource, weekday: 1, start_minute: 15 * 60, end_minute: 16 * 60)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))

    payload = search(date)

    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
  end

  it 'uses provider hours after local working rules change' do
    date = Date.new(2026, 4, 20)
    resource.work_rules.find_by!(weekday: 1).update!(start_minute: 16 * 60)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))

    payload = search(date)

    expect(payload[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
  end

  it 'ignores a local holiday, vacation and workday override for a provider specialist' do
    date = Date.new(2026, 4, 20)
    create(:scheduling_holiday, account: account, date: date)
    create(:scheduling_time_off, account: account, resource: resource,
                                 starts_at: zone.local(2026, 4, 20, 15), ends_at: zone.local(2026, 4, 20, 16))
    create(:scheduling_workday_override, account: account, resource: resource, date: date,
                                         start_minute: 9 * 60, end_minute: 12 * 60)
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))

    expect(search(date)[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 15).iso8601)
  end

  it 'excludes a local appointment and an active provider reception' do
    date = Date.new(2026, 4, 20)
    create(:scheduling_appointment, account: account, resource: resource,
                                    starts_at: zone.local(2026, 4, 20, 15), ends_at: zone.local(2026, 4, 20, 15, 30))
    allow(client).to receive(:timetable).and_return(provider_day(date, from_hour: 15, to_hour: 17))
    allow(client).to receive(:get_receptions).and_return(
      [{ 'STARTTIME' => '20.04.2026 15:30:00', 'ENDTIME' => '20.04.2026 16:00:00', 'REMOVED' => 0 }]
    )

    expect(search(date)[:slots].first[:starts_at]).to eq(zone.local(2026, 4, 20, 16).iso8601)
  end

  it 'clips the provider request at the final bookable date' do
    last_date = Date.new(2026, 7, 18)
    allow(client).to receive(:timetable).and_return(provider_day(last_date, from_hour: 10, to_hour: 12))

    payload = described_class.new(account: account, resource_ids: [resource.id],
                                  from: zone.local(2026, 7, 18, 9), to: zone.local(2026, 7, 20, 9),
                                  duration_min: 30).perform

    expect(payload[:slots].pluck(:starts_at)).to include(zone.local(2026, 7, 18, 10).iso8601)
    expect(payload[:slots].all? { |slot| Time.iso8601(slot[:starts_at]) < zone.local(2026, 7, 19) }).to be(true)
    expect(client).to have_received(:timetable).with(
      specialist_code: 'specialist-1', starts_on: last_date, ends_on: last_date
    )
  end

  it 'does not call the provider beyond the horizon' do
    expect(client).not_to receive(:timetable)
    expect(search(Date.new(2026, 7, 19))[:slots]).to be_empty
  end

  it 'does not list an unpublished specialist' do
    resource.update!(active: false, custom_attributes: resource.custom_attributes.merge('medelement_schedule_published' => false))

    expect do
      search(Date.new(2026, 4, 20))
    end.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'reports an unavailable provider as unverified' do
    allow(client).to receive(:timetable).and_raise(
      Integrations::Medelement::Client::ApiError.new('unavailable', status: 504)
    )

    payload = search(Date.new(2026, 4, 20))

    expect(payload[:slots]).to be_empty
    expect(payload[:availability]).to include(status: 'degraded', resources: [include(status: 'unavailable')])
    expect(payload[:availability_note]).to include('наличие свободного времени неизвестно')
  end
end
