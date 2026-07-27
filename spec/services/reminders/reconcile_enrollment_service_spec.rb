require 'rails_helper'

RSpec.describe Reminders::ReconcileEnrollmentService do
  let(:account) { create(:account).tap { |record| record.enable_features!('deferred_touch_materialization') } }
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
        {
          body: 'Live plan step',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          timezone: 'UTC'
        }
      ]
    )
  end
  let(:enrollment) do
    Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
  end

  def materialize_step
    Reminders::MaterializeEnrollmentStepService.new(
      enrollment: enrollment,
      now: enrollment.next_due_at + 1.minute
    ).perform
  end

  it 'keeps archived plans available to existing enrollments' do
    enrollment
    reminder_group.archive!

    claim = materialize_step

    expect(claim).to be_materialized
    expect(claim.reminder.body).to eq('Live plan step')
  end

  it 'cancels an active enrollment when its live plan is deleted' do
    enrollment

    reminder_group.destroy!

    expect(enrollment.reload).to be_cancelled
    expect(enrollment.reminder_group).to be_nil
  end

  it 'cancels an undelivered materialized step when the step is removed' do
    claim = materialize_step
    reminder_group.update!(touches: [])

    described_class.new(enrollment: enrollment).perform

    expect(claim.reminder.reload).to be_cancelled
    expect(claim.reload).to have_attributes(
      status: 'skipped',
      last_error: Reminders::ReconcileEnrollmentService::STEP_REMOVED
    )
    expect(enrollment.reload).to be_completed
  end

  it 'preserves a completed enrollment after its delivery was already materialized' do
    claim = materialize_step
    claim.reminder.mark_processing!
    claim.reminder.mark_delivery_materialized!(123)

    reminder_group.destroy!

    expect(enrollment.reload).to be_completed
    expect(claim.reminder.reload).to be_processing
    expect(claim.reminder.metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY]).to eq(123)
  end
end
