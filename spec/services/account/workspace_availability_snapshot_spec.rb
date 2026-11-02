require 'rails_helper'

RSpec.describe Account::WorkspaceAvailabilitySnapshot do
  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:at) { zone.local(2026, 9, 7, 12, 30) }

  before do
    account.update!(
      workspace_timezone: zone.tzinfo.name,
      workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup,
      workspace_breaks: [{ days: [1, 2, 3, 4, 5], start_time: '13:00', end_time: '14:00' }],
      workspace_days_off: [{ date: '2026-09-08', recurring_yearly: false }]
    )
  end

  def projected_open?(snapshot, time)
    snapshot[:intervals].any? { |interval| time >= Time.iso8601(interval[:starts_at]) && time < Time.iso8601(interval[:ends_at]) }
  end

  it 'projects company hours, breaks and days off as absolute half-open intervals' do
    snapshot = described_class.new(account: account, at: at).as_json

    expect(projected_open?(snapshot, zone.local(2026, 9, 7, 12, 59))).to be(true)
    expect(projected_open?(snapshot, zone.local(2026, 9, 7, 13, 0))).to be(false)
    expect(projected_open?(snapshot, zone.local(2026, 9, 7, 14, 0))).to be(true)
    expect(projected_open?(snapshot, zone.local(2026, 9, 7, 17, 0))).to be(false)
    expect(projected_open?(snapshot, zone.local(2026, 9, 8, 10, 0))).to be(false)
    expect(snapshot[:valid_until]).to eq(zone.local(2026, 9, 21).utc.iso8601)
  end

  it 'matches the canonical server policy throughout its horizon' do
    snapshot = described_class.new(account: account, at: at).as_json
    first = Time.iso8601(snapshot[:valid_from])

    (0...(14 * 24 * 6)).each do |offset|
      time = first + (offset * 10.minutes)
      expect(projected_open?(snapshot, time)).to eq(account.workspace_open_at?(time)), "at #{time}"
    end
  end

  it 'keeps an account without configured hours open, as the server does' do
    account.update!(workspace_working_hours: nil)
    snapshot = described_class.new(account: account, at: at).as_json

    expect(snapshot[:intervals]).to eq([{ starts_at: snapshot[:valid_from], ends_at: snapshot[:valid_until] }])
  end

  it 'invalidates the projection when the company schedule changes' do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    original_policy = account.method(:workspace_open_at?)
    checks = 0
    allow(account).to receive(:workspace_open_at?) do |time|
      checks += 1
      original_policy.call(time)
    end
    snapshot = described_class.new(account: account, at: at).as_json
    expect(projected_open?(snapshot, at)).to be(true)
    first_checks = checks
    expect(described_class.new(account: account, at: at).as_json).to eq(snapshot)
    expect(checks).to eq(first_checks)

    account.update!(workspace_days_off: [{ date: '2026-09-07' }])
    changed = described_class.new(account: account, at: at).as_json
    expect(projected_open?(changed, at)).to be(false)
    expect(checks).to be > first_checks
  end

  it 'excludes recurring days off without publishing their private titles' do
    account.update!(workspace_days_off: [{ date: '2025-09-07', recurring_yearly: true, title: 'Private reason' }])
    snapshot = described_class.new(account: account, at: at).as_json

    expect(projected_open?(snapshot, at)).to be(false)
    expect(snapshot.to_json).not_to include('Private reason')
  end

  context 'when a local hour repeats at the daylight-saving transition' do
    let(:zone) { ActiveSupport::TimeZone['America/New_York'] }
    let(:at) { Time.iso8601('2026-11-01T04:00:00Z') }

    it 'preserves both occurrences of a break in that hour' do
      schedule = AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup
      schedule[0] = {
        'day_of_week' => 0, 'closed_all_day' => false, 'open_all_day' => false,
        'open_hour' => 0, 'open_minutes' => 0, 'close_hour' => 4, 'close_minutes' => 0
      }
      account.update!(workspace_working_hours: schedule, workspace_breaks: [{ days: [0], start_time: '01:15', end_time: '01:45' }])
      snapshot = described_class.new(account: account, at: at).as_json

      %w[2026-11-01T05:30:00Z 2026-11-01T06:30:00Z].each do |clock|
        expect(projected_open?(snapshot, Time.iso8601(clock))).to be(false)
      end
      %w[2026-11-01T05:50:00Z 2026-11-01T06:10:00Z 2026-11-01T07:00:00Z].each do |clock|
        expect(projected_open?(snapshot, Time.iso8601(clock))).to be(true)
      end
    end
  end
end
