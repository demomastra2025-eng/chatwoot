require 'rails_helper'
require Rails.root.join('db/migrate/20260907220000_enforce_single_scheduling_work_rule_per_weekday')

RSpec.describe EnforceSingleSchedulingWorkRulePerWeekday do
  it 'reactivates an existing break that matches a merged interval gap' do
    resource = create(:scheduling_resource)
    resource.work_rules.create!(weekday: 1, start_minute: 540, end_minute: 720, active: true)
    resource.work_rules.create!(weekday: 1, start_minute: 780, end_minute: 1020, active: true)
    gap = resource.break_rules.create!(
      weekday: 1,
      start_minute: 720,
      end_minute: 780,
      title: 'Existing gap',
      active: false
    )

    described_class.new.send(:normalize_day!, resource.id, 1)

    expect(resource.work_rules.reload).to contain_exactly(
      have_attributes(start_minute: 540, end_minute: 1020, active: true)
    )
    expect(gap.reload).to have_attributes(active: true)
  end
end
