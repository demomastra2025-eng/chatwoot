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

  def stub_timetable
    allow(client).to receive(:timetable) do |**options|
      if (options.fetch(:ends_on) - options.fetch(:starts_on)).to_i >= Integrations::Medelement::Client::MAX_TIMETABLE_DAYS
        raise Integrations::Medelement::Client::ApiError.new('Range exceeds seven days', status: 400)
      end

      yield(**options)
    end
  end

  it 'stores all 90 days through 13 requests of at most seven days' do
    resource
    requests = []
    stub_timetable do |starts_on:, ends_on:, **|
      requests << [starts_on, ends_on]
      answer(starts_on, ends_on) do |day|
        working_day(day, [true, 1, 'true', '1'].map { |value| working_row(day, value: value) })
      end
    end

    result = sync
    stored = Integrations::Medelement::ScheduleDay.where(account: account, hook: hook)

    expect(result).to include(created_count: 90, request_count: 13, unverified_count: 0, skipped_count: 0)
    expect(requests).to eq((0..12).map do |index|
      [date + (index * 7), [date + (index * 7) + 6, date + 89].min]
    end)
    expect(stored.count).to eq(90)
    expect(stored.find_by!(resource: resource, date: date).windows.map { |window| window['working'] }).to eq([true, 1, 'true', '1'])
    expect(stored.find_by!(resource: resource, date: date + 1).windows.first).to include(
      'start_minute' => 540, 'end_minute' => 600, 'cabinet_code' => 'room-1', 'type' => 'work'
    )
    expect(sync).to include(request_count: 0, skipped_count: 0)
  end

  it 'refreshes near, far and long days at their own intervals' do
    resource
    requested_dates = []
    stub_timetable do |starts_on:, ends_on:, **|
      requested_dates << [starts_on, ends_on]
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 61.minutes).iso8601))
    requested_dates.clear

    expect(sync(at: now + 61.minutes)).to include(request_count: 1, updated_count: 2)
    expect(requested_dates).to eq([[date, date + 1]])

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 13.hours).iso8601))
    requested_dates.clear
    expect(sync(at: now + 13.hours)).to include(request_count: 2, updated_count: 14)
    expect(requested_dates).to eq([[date, date + 6], [date + 7, date + 13]])

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 25.hours).iso8601))
    requested_dates.clear
    expect(sync(at: now + 25.hours)).to include(request_count: 13, updated_count: 89, created_count: 1)
    expect(requested_dates.first).to eq([date + 1, date + 7])
    expect(requested_dates.last).to eq([date + 85, date + 90])
  end

  it 'caps HTTP windows and leaves unrefreshed days due for later runs' do
    stub_const('Integrations::Medelement::SchedulesSyncService::REQUEST_CAP', 2)
    resource
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }

    expect(sync).to include(request_count: 2, created_count: 14, skipped_count: 76)
    expect(sync).to include(request_count: 2, created_count: 14, skipped_count: 62)
    expect(Integrations::Medelement::ScheduleDay.where(resource: resource).count).to eq(28)
  end

  it 'prioritizes the oldest checked window across doctors when capped' do
    other = specialist(account, 'doctor-2', now)
    resource
    requested = []
    stub_timetable do |specialist_code:, starts_on:, ends_on:, **|
      requested << [specialist_code, starts_on, ends_on]
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    Integrations::Medelement::ScheduleDay.where(resource: other, date: (date + 21)..(date + 27))
                                         .find_each { |day| day.update!(source_checked_at: now - 2.days) }
    [resource, other].each do |doctor|
      doctor.update!(custom_attributes: doctor.custom_attributes.merge('medelement_last_seen_at' => (now + 13.hours).iso8601))
    end
    stub_const('Integrations::Medelement::SchedulesSyncService::REQUEST_CAP', 1)
    requested.clear

    expect(sync(at: now + 13.hours)).to include(request_count: 1, skipped_count: 28)
    expect(requested).to eq([['doctor-2', date + 21, date + 27]])
  end

  it 'requests only due dates when they have gaps' do
    resource
    requested = []
    stub_timetable do |starts_on:, ends_on:, **|
      requested << [starts_on, ends_on]
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    Integrations::Medelement::ScheduleDay.where(resource: resource, date: [date + 2, date + 5])
                                         .find_each { |day| day.update!(source_checked_at: nil) }
    requested.clear

    expect(sync).to include(request_count: 2, updated_count: 2)
    expect(requested).to eq([[date + 2, date + 2], [date + 5, date + 5]])
  end

  it 'continues after failing windows and doctors, then raises the first API error' do
    resource
    specialist(account, 'doctor-2', now)
    first_error = Integrations::Medelement::Client::ApiError.new('First failure', status: 503)
    second_error = Integrations::Medelement::Client::ApiError.new('Second failure', status: 503)
    stub_timetable do |specialist_code:, starts_on:, ends_on:, **|
      raise first_error if specialist_code == 'doctor-1' && starts_on == date + 7
      raise second_error if specialist_code == 'doctor-2' && starts_on == date + 14

      answer(starts_on, ends_on) { |day| working_day(day) }
    end

    expect { sync }.to raise_error(Integrations::Medelement::Client::ApiError) do |error|
      expect(error).to equal(first_error)
    end
    expect(client).to have_received(:timetable).exactly(26).times
    days = Integrations::Medelement::ScheduleDay.where(account: account, hook: hook)
    expect(days.count).to eq(180)
    expect(days.where(status: 'unverified').count).to eq(14)
    expect(days.where(resource: resource, date: date + 7).first.source_checked_at).to be_nil
    expect(days.where(resource: resource, date: date + 14).first.source_checked_at).to eq(now)
  end

  it 'prunes only this hook\'s rows older than yesterday after a successful run' do
    resource
    other_account = create(:account)
    other_account.enable_features!('scheduling')
    other_resource = specialist(other_account, 'other-doctor', now)
    other_hook = create(:integrations_hook, :medelement, account: other_account)
    old = Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'doctor-1', date: date - 2
    )
    yesterday = Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'doctor-1', date: date - 1
    )
    foreign = Integrations::Medelement::ScheduleDay.create!(
      account: other_account, hook: other_hook, resource: other_resource, specialist_code: 'other-doctor', date: date - 2
    )
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }

    sync

    expect(Integrations::Medelement::ScheduleDay.exists?(old.id)).to be(false)
    expect(Integrations::Medelement::ScheduleDay.exists?(yesterday.id)).to be(true)
    expect(Integrations::Medelement::ScheduleDay.exists?(foreign.id)).to be(true)
  end

  it 'preserves old windows through a first empty answer and confirms only the second' do
    resource
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { day_off } }
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
    stub_timetable do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day) }
    end
    sync
    records = Integrations::Medelement::ScheduleDay.where(resource: resource, date: date..(date + 3))
    records.update_all(source_checked_at: now - 12.hours)
    prior = records.index_by(&:date).transform_values { |record| [record.windows, record.source_checked_at, record.raw_digest] }
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    stub_timetable do |starts_on:, ends_on:, **|
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
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    original_windows = stored.windows
    original_checked_at = stored.source_checked_at
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    stub_timetable { {} }

    expect(sync(at: now + 1.hour)).to include(unverified_count: 2, request_count: 1)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)

    stub_timetable { [] }
    expect(sync(at: now + 1.hour)).to include(unverified_count: 2, request_count: 1)
    expect(stored.reload).to have_attributes(status: 'unverified', windows: original_windows,
                                             source_checked_at: original_checked_at)
  end

  it 'does not count a malformed working row as a day off' do
    resource
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    old_windows = stored.windows
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    stub_timetable do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day, [{ 'working' => true }]) }
    end

    sync(at: now + 1.hour)

    expect(stored.reload).to have_attributes(status: 'unverified', consecutive_empty_count: 0, windows: old_windows)

    stub_timetable do |starts_on:, ends_on:, **|
      answer(starts_on, ends_on) { |day| working_day(day, [working_row(day, value: false)]) }
    end
    sync(at: now + 1.hour)
    expect(stored.reload).to have_attributes(status: 'unverified', consecutive_empty_count: 0, windows: old_windows)
  end

  it 'keeps saved windows on a provider error and lets the existing job retry the phase' do
    resource
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }
    sync
    stored = Integrations::Medelement::ScheduleDay.find_by!(resource: resource, date: date)
    old_windows = stored.windows
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_last_seen_at' => (now + 1.hour).iso8601))
    error = Integrations::Medelement::Client::ApiError.new('Provider unavailable', status: 503)
    stub_timetable { raise error }

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
    stub_timetable { |starts_on:, ends_on:, **| answer(starts_on, ends_on) { |day| working_day(day) } }

    expect(sync).to include(request_count: 13)
    expect(Integrations::Medelement::ScheduleDay.distinct.pluck(:resource_id)).to eq([active.id])
  end
end
