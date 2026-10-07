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

  def answer(starts_on, ends_on)
    (starts_on..ends_on).to_h { |day| [day.strftime('%d.%m.%Y'), yield(day)] }
  end

  def working_day(day, rows = [working_row(day)])
    {
      'timetable' => rows,
      'clinicWorkingHours' => { 'start' => day.strftime('%d.%m.%Y 08:00'), 'end' => day.strftime('%d.%m.%Y 18:00') },
      'specialistWorkingHours' => {
        'start' => day.strftime('%d.%m.%Y 08:00'), 'end' => day.strftime('%d.%m.%Y 18:00'),
        'start_lunch' => '', 'end_lunch' => '', 'time_off' => []
      }
    }
  end

  def day_off
    { 'timetable' => [], 'specialistWorkingHours' => 'day off' }
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

  it 'stores the complete 14-day horizon with one range request per doctor' do
    doctors = [resource, specialist(account, 'doctor-2', now)]
    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) do |day|
        working_day(day, [true, 1, 'true', '1'].map { |value| working_row(day, value: value) })
      end
    end

    result = sync
    stored = Integrations::Medelement::ScheduleDay.where(account: account, hook: hook)

    expect(result).to include(created_count: 28, request_count: 2, unverified_count: 0)
    doctors.each do |doctor|
      expect(client).to have_received(:timetable).with(specialist_code: doctor.custom_attributes['medelement_specialist_code'],
                                                      starts_on: date, ends_on: date + 13, allow_partial: true).once
    end
    expect(stored.count).to eq(28)
    expect(stored.find_by!(resource: resource, date: date).windows.map { |window| window['working'] }).to eq([true, 1, 'true', '1'])
    expect(stored.find_by!(resource: resource, date: date + 1).windows.first).to include('start_minute' => 540, 'end_minute' => 600,
                                                                 'cabinet_code' => 'room-1', 'type' => 'work')
  end

  it 'refreshes only today and tomorrow after an hour, then the older horizon after twelve hours' do
    resource
    requested_dates = []
    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      requested_dates << [starts_on, ends_on]
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 61.minutes).iso8601))

    expect(sync(at: now + 61.minutes)).to include(request_count: 1, updated_count: 2)

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 11.hours + 30.minutes).iso8601))
    expect(sync(at: now + 11.hours + 30.minutes)).to include(request_count: 1)

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 12.hours).iso8601))
    requested_dates.clear
    expect(sync(at: now + 12.hours)).to include(request_count: 1)
    expect(requested_dates).to eq([[date + 2, date + 13]])
  end

  it 'caps doctor requests and carries untouched doctors into the next run' do
    stub_const('Integrations::Medelement::SchedulesSyncService::REQUEST_CAP', 2)
    doctors = [resource, specialist(account, 'doctor-2', now), specialist(account, 'doctor-3', now)]
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }

    expect(sync).to include(request_count: 2, skipped_count: 14)
    expect(sync).to include(request_count: 1, skipped_count: 0)
    doctors.each { |doctor| expect(Integrations::Medelement::ScheduleDay.where(resource: doctor).count).to eq(14) }
  end

  it 'preserves old windows through a first empty answer and confirms only the second' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { day_off } }
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))

    sync(at: now + 1.hour)
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    expect(stored.reload).to have_attributes(status: 'empty_unconfirmed', consecutive_empty_count: 1)
    expect(stored.windows).not_to be_empty

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 2.hours).iso8601))
    sync(at: now + 2.hours)
    expect(stored.reload).to have_attributes(status: 'empty_confirmed', consecutive_empty_count: 2, windows: [])
  end

  it 'splits mixed range days and leaves empty-hours, reversed-hours and missing days unverified' do
    resource
    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    records = Integrations::Medelement::ScheduleDay.where(resource: resource, date: date..(date + 3))
    records.update_all(source_checked_at: now - 12.hours)
    prior = records.index_by(&:date).transform_values { |record| [record.windows, record.source_checked_at, record.raw_digest] }
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) do |day|
        case (day - date).to_i
        when 0 then day_off
        when 1 then working_day(day, [])
        when 2
          working_day(day).merge('specialistWorkingHours' => {
            'start' => day.strftime('%d.%m.%Y 08:00'), 'end' => day.strftime('%d.%m.%Y 00:00')
          })
        else working_day(day)
        end
      end.except((date + 3).strftime('%d.%m.%Y'))
    end

    expect(sync(at: now + 1.hour)).to include(request_count: 1, unverified_count: 3)
    expect(records.find_by!(date: date).reload).to have_attributes(status: 'empty_unconfirmed', consecutive_empty_count: 1)
    [date + 1, date + 2, date + 3].each do |day|
      saved = records.find_by!(date: day).reload
      expect(saved).to have_attributes(status: 'unverified', consecutive_empty_count: 0,
                                       windows: prior.fetch(day)[0], source_checked_at: prior.fetch(day)[1],
                                       raw_digest: prior.fetch(day)[2])
    end
  end

  it 'marks a partial answer unverified without changing the saved data or source timestamp' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    original_windows = stored.windows
    original_checked_at = stored.source_checked_at
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    allow(client).to receive(:timetable).and_return({})

    expect(sync(at: now + 1.hour)).to include(unverified_count: 2, request_count: 1)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)

    allow(client).to receive(:timetable).and_return([])
    expect(sync(at: now + 1.hour)).to include(unverified_count: 2, request_count: 1)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)
  end

  it 'does not count a malformed working row as a day off' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    old_windows = stored.windows
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day, [{ 'working' => true }]) }
    end

    sync(at: now + 1.hour)

    expect(stored.reload).to have_attributes(status: 'unverified', consecutive_empty_count: 0, windows: old_windows)

    allow(client).to receive(:timetable) do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day, [working_row(day, value: false)]) }
    end
    sync(at: now + 1.hour)
    expect(stored.reload).to have_attributes(status: 'unverified', consecutive_empty_count: 0, windows: old_windows)
  end

  it 'keeps saved windows on a provider error and lets the existing job retry the phase' do
    resource
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
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
    allow(client).to receive(:timetable) { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }

    expect(sync).to include(request_count: 1)
    expect(Integrations::Medelement::ScheduleDay.distinct.pluck(:resource_id)).to eq([active.id])
  end
end
