require 'rails_helper'

RSpec.describe Reminders::PlanApplicationService do
  let(:account) { create(:account) }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
  end
  let(:reminder_group) { create(:reminder_group, account: account) }

  def perform
    described_class.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
  end

  it 'keeps the eager path when the feature is disabled' do
    result = perform

    expect(result.execution_mode).to eq('eager')
    expect(result.touches.size).to eq(1)
    expect(account.touch_plan_enrollments).to be_empty
  end

  it 'creates an enrollment without future reminders when enabled' do
    account.enable_features!('deferred_touch_materialization')

    result = perform

    expect(result.execution_mode).to eq('deferred')
    expect(result.touches).to be_empty
    expect(result.enrollment).to have_attributes(remindable: appointment, reminder_group: reminder_group)
    expect(result.enrollment.next_due_at).to be_within(2.seconds).of(appointment.starts_at - 1.day)
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'reuses an open enrollment when the same plan application is retried' do
    account.enable_features!('deferred_touch_materialization')
    service = described_class.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    )

    first = service.perform
    second = service.perform

    expect(second.enrollment).to eq(first.enrollment)
    expect(account.touch_plan_enrollments.count).to eq(1)
    expect(account.reminders).to be_empty
  end

  it 'falls back to eager for an unsupported recurring plan' do
    account.enable_features!('deferred_touch_materialization')
    reminder_group.update!(
      touches: [
        reminder_group.touches.first.merge(
          'timing_mode' => 'absolute',
          'scheduled_at' => 2.days.from_now.iso8601,
          'repeat_mode' => 'daily',
          'repeat_until_at' => 5.days.from_now.iso8601
        )
      ]
    )

    expect(perform.execution_mode).to eq('eager')
  end
end
