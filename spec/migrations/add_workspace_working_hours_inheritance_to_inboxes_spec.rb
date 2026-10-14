require 'rails_helper'
require Rails.root.join('db/migrate/20260901131000_add_workspace_working_hours_inheritance_to_inboxes')

RSpec.describe AddWorkspaceWorkingHoursInheritanceToInboxes do
  it 'copies an enabled inbox schedule once and leaves accounts without one unscheduled' do
    account = create(:account)
    inbox = create(:inbox, account: account, working_hours_enabled: true, timezone: 'Asia/Almaty')
    other = create(:account)
    create(:inbox, account: other, working_hours_enabled: false)
    inbox.working_hours.find_by!(day_of_week: 1).update!(open_hour: 10)

    described_class.new.up

    expect(account.reload.workspace_working_hours_schedule.find { |day| day['day_of_week'] == 1 }['open_hour']).to eq(10)
    expect(inbox.reload.inherit_working_hours_from_account?).to be(true)
    expect(other.reload.workspace_working_hours_configured?).to be(false)
    expect(other.workspace_open_at?).to be(true)

    account.update!(workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup)
    described_class.new.up
    expect(account.reload.workspace_working_hours_schedule.find { |day| day['day_of_week'] == 1 }['open_hour']).to eq(9)
  end
end
