require 'rails_helper'

RSpec.describe Integrations::Medelement::SchedulesSyncService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:configuration) { Integrations::Medelement::Configuration.new(hook: hook) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:now) { Time.zone.parse('2026-10-07 09:00:00 +0500') }
  let(:date) { now.in_time_zone(configuration.time_zone).to_date }
  let(:resource) { specialist(account, 'doctor-1', now) }

  before { account.enable_features!('scheduling') }

  def specialist(owner, code, seen_at, active: true)
    create(:scheduling_resource, account: owner, active: active, custom_attributes: {
             'medelement_specialist_code' => code,
             'medelement_last_seen_at' => seen_at.iso8601
           })
  end

  def answer(day, rows)
    { day.strftime('%d.%m.%Y') => { 'timetable' => rows } }
  end

  def working_row(day, value: true)
    {
      'start' => day.strftime('%d.%m.%Y 09:00'),
      'end' => day.strftime('%d.%m.%Y 10:00'),
      'working' => value,
      'cabinetCode' => 'room-1',
      'type' => 'work'
    }
  end

  def sync(at: now)
    described_class.new(hook: hook, client: client, configuration: configuration, now: at).perform
  end

  it 'stores the complete 14-day horizon and accepts all provider working values' do
    resource
    allow(client).to receive(:timetable) do |starts_on:, **|
      answer(starts_on, [true, 1, 'true', '1'].map { |value| working_row(starts_on, value: value) })
    end

    result = sync
    stored = Integrations::Medelement::ScheduleDay.where(account: account, hook: hook, resource: resource)

    expect(result).to include(created_count: 14, request_count: 14, unverified_count: 0)
    expect(stored.count).to eq(14)
    expect(stored.find_by!(date: date).windows.map { |window| window['working'] }).to eq([true, 1, 'true', '1'])
    expect(stored.find_by!(date: date).windows.first).to include('start_minute' => 540, 'end_minute' => 600,
                                                                 'cabinet_code' => 'room-1', 'type' => 'work')
  end

  it 'refreshes only today and tomorrow after an hour, then the older horizon after twelve hours' do
    resource
    requested_dates = []
    allow(client).to receive(:timetable) do |starts_on:, **|
      requested_dates << starts_on
      answer(starts_on, [working_row(starts_on)])
    end
    sync
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 61.minutes).iso8601))

    expect(sync(at: now + 61.minutes)).to include(request_count: 2, updated_count: 2)

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 11.hours + 30.minutes).iso8601))
    expect(sync(at: now + 11.hours + 30.minutes)).to include(request_count: 2)

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 12.hours).iso8601))
    requested_dates.clear
    expect(sync(at: now + 12.hours)).to include(request_count: 12)
    expect(requested_dates).to match_array((2...14).map { |offset| date + offset })
  end

  it 'caps requests and carries untouched days into the next run' do
    stub_const('Integrations::Medelement::SchedulesSyncService::REQUEST_CAP', 2)
    resource
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }

    expect(sync).to include(request_count: 2, skipped_count: 12)
    expect(sync).to include(request_count: 2, skipped_count: 10)
    expect(Integrations::Medelement::ScheduleDay.where(resource: resource).pluck(:date)).to contain_exactly(
      date, date + 1, date + 2, date + 3
    )
  end

  it 'preserves old windows through a first empty answer and confirms only the second' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }
    sync
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, []) }
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))

    sync(at: now + 1.hour)
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    expect(stored.reload).to have_attributes(status: 'empty_unconfirmed', consecutive_empty_count: 1)
    expect(stored.windows).not_to be_empty

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 2.hours).iso8601))
    sync(at: now + 2.hours)
    expect(stored.reload).to have_attributes(status: 'empty_confirmed', consecutive_empty_count: 2, windows: [])
  end

  it 'marks a partial answer unverified without changing the saved data or source timestamp' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    original_windows = stored.windows
    original_checked_at = stored.source_checked_at
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    allow(client).to receive(:timetable).and_return({})

    expect(sync(at: now + 1.hour)).to include(unverified_count: 2)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)

    allow(client).to receive(:timetable).and_return([])
    expect(sync(at: now + 1.hour)).to include(unverified_count: 2)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)
  end

  it 'does not count a malformed working row as a day off' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    old_windows = stored.windows
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [{ 'working' => 'true' }]) }

    sync(at: now + 1.hour)

    expect(stored.reload).to have_attributes(status: 'unverified', consecutive_empty_count: 0, windows: old_windows)
  end

  it 'keeps saved windows on a provider error and lets the existing job retry the phase' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    old_windows = stored.windows
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    error = Integrations::Medelement::Client::ApiError.new('Provider unavailable', status: 503)
    allow(client).to receive(:timetable).and_raise(error)

    expect { sync(at: now + 1.hour) }.to raise_error(error)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: old_windows, source_checked_at: now)
  end

  it 'skips inactive, stale and foreign-account doctors' do
    active = resource
    specialist(account, 'inactive', now, active: false)
    specialist(account, 'stale', now - 2.hours)
    other_account = create(:account)
    other_account.enable_features!('scheduling')
    specialist(other_account, 'foreign', now)
    allow(client).to receive(:timetable) { |starts_on:, **| answer(starts_on, [working_row(starts_on)]) }

    expect(sync).to include(request_count: 14)
    expect(Integrations::Medelement::ScheduleDay.distinct.pluck(:resource_id)).to eq([active.id])
  end
end
