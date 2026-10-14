require 'rails_helper'

RSpec.describe Scheduling::Resource do
  let(:account) { create(:account) }

  before do
    account.update!(workspace_timezone: 'Asia/Almaty',
                    workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup)
  end

  it 'inherits the company schedule for a new specialist' do
    resource = account.scheduling_resources.create!(name: 'Specialist', slot_duration_min: 30)

    expect(resource.inherit_working_hours_from_account?).to be(true)
    expect(resource.work_rules.count).to eq(7)
    expect(resource.work_rules.find_by!(weekday: 1)).to have_attributes(start_minute: 540, end_minute: 1020)
  end

  it 'keeps a specialist personal schedule when the company hours change' do
    resource = create(:scheduling_resource, account: account, inherit_working_hours_from_account: false)
    personal_rule = create(:scheduling_work_rule, resource: resource, account: account,
                                                  weekday: 1, start_minute: 600, end_minute: 900)
    schedule = AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup
    schedule[1]['open_hour'] = 8
    account.update!(workspace_working_hours: schedule)

    expect(personal_rule.reload).to have_attributes(start_minute: 600, end_minute: 900, active: true)
  end
end
