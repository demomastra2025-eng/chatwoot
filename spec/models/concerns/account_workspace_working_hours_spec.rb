require 'rails_helper'

RSpec.describe AccountWorkspaceWorkingHours do
  let(:account) { create(:account) }
  let(:schedule) { described_class::DEFAULT_SCHEDULE.deep_dup }
  let(:almaty) { ActiveSupport::TimeZone['Asia/Almaty'] }

  before do
    account.update!(
      workspace_working_hours_enabled: false,
      workspace_timezone: 'Asia/Almaty',
      workspace_working_hours: schedule,
      workspace_breaks: [
        {
          days: [1, 2, 3, 4, 5],
          start_time: '13:00',
          end_time: '14:00',
          title: 'Lunch'
        }
      ],
      workspace_days_off: [
        { date: '2026-09-08', title: 'Company day off', recurring_yearly: false },
        { date: '2025-12-16', title: 'Independence Day', recurring_yearly: true }
      ]
    )
  end

  it 'keeps company working hours enabled regardless of the legacy setting' do
    expect(account.workspace_working_hours_enabled?).to be(true)
  end

  it 'evaluates weekly hours, breaks, one-time days off and yearly days off' do
    expect(account.workspace_open_at?(almaty.local(2026, 9, 7, 12, 30))).to be(true)
    expect(account.workspace_open_at?(almaty.local(2026, 9, 7, 13, 30))).to be(false)
    expect(account.workspace_open_at?(almaty.local(2026, 9, 7, 17, 0))).to be(false)
    expect(account.workspace_open_at?(almaty.local(2026, 9, 7, 18, 1))).to be(false)
    expect(account.workspace_open_at?(almaty.local(2026, 9, 8, 12, 0))).to be(false)
    expect(account.workspace_open_at?(almaty.local(2026, 12, 16, 12, 0))).to be(false)
  end

  it 'makes a new inbox inherit the company schedule and use breaks for out-of-office checks' do
    inbox = create(:inbox, account: account)

    expect(inbox).to have_attributes(
      inherit_working_hours_from_account: true,
      working_hours_enabled: true,
      timezone: 'Asia/Almaty'
    )
    travel_to(almaty.local(2026, 9, 7, 13, 30)) do
      expect(inbox).to be_out_of_office
    end
  end

  it 'rejects a weekly schedule with duplicate or missing weekdays' do
    invalid_schedule = schedule.deep_dup
    invalid_schedule.last['day_of_week'] = 5

    expect(account.update(workspace_working_hours: invalid_schedule)).to be(false)
    expect(account.errors[:workspace_working_hours]).to include('must contain each weekday exactly once')
  end
end
