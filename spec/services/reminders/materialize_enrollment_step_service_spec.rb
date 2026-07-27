require 'rails_helper'

RSpec.describe Reminders::MaterializeEnrollmentStepService do
  let(:account) { create(:account) }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
  end
  let(:reminder_group) do
    create(
      :reminder_group,
      account: account,
      touches: [
        attributes_for(:reminder).slice(:body).merge(
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          timezone: 'UTC'
        )
      ]
    )
  end
  let(:enrollment) do
    account.enable_features!('deferred_touch_materialization')
    Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
  end

  it 'creates one occurrence claim and one normal reminder when due' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform

    expect(claim).to be_materialized
    expect(claim.reminder).to be_present
    expect(claim.reminder.metadata).to include('touch_plan_enrollment_id' => enrollment.id)
  end

  it 'keeps the materialized reminder executable after the enrollment completes' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    claim.reminder.mark_processing!

    result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

    expect(enrollment.reload).to be_completed
    expect(result).to eq(Reminders::ExecutionScheduleGuard::CONTINUE)
    expect(claim.reminder.reload).to be_processing
  end

  it 'keeps a materialized reminder executable when the feature pauses later occurrences' do
    reminder_group.update!(
      touches: [
        reminder_group.touches.first,
        reminder_group.touches.first.merge(
          'body' => 'Later step',
          'relative_offset_seconds' => -23.hours.to_i
        )
      ]
    )
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    account.disable_features!('deferred_touch_materialization')

    described_class.new(enrollment: enrollment, now: enrollment.reload.next_due_at).perform
    claim.reminder.mark_processing!

    expect(enrollment.reload).to be_paused
    expect(enrollment.metadata['paused_reason']).to eq('deferred_touch_materialization')
    expect(Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform).to eq(
      Reminders::ExecutionScheduleGuard::CONTINUE
    )
    expect(claim.reminder.reload).to be_processing
  end

  it 'is idempotent across repeated execution' do
    now = enrollment.next_due_at + 1.minute

    2.times { described_class.new(enrollment: enrollment, now: now).perform }

    expect(enrollment.touch_occurrence_claims.count).to eq(1)
    expect(account.reminders.where(remindable: appointment).count).to eq(1)
  end

  it 'skips a trigger that is older than the grace window' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 10.minutes).perform

    expect(claim).to have_attributes(status: 'skipped', last_error: 'missed_due_to_reschedule')
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'cancels the enrollment for a terminal appointment' do
    appointment.update!(status: 'cancelled')

    described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform

    expect(enrollment.reload).to have_attributes(status: 'cancelled', next_due_at: nil)
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end
end
