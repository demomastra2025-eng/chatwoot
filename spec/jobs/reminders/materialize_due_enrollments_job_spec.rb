require 'rails_helper'

RSpec.describe Reminders::MaterializeDueEnrollmentsJob do
  include ActiveJob::TestHelper

  it 'materializes only due active enrollments' do
    account = create(:account)
    account.enable_features!('deferred_touch_materialization')
    appointment = create(
      :scheduling_appointment,
      account: account,
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
    reminder_group = create(
      :reminder_group,
      account: account,
      touches: [
        {
          body: 'Due now',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          timezone: 'UTC'
        }
      ]
    )
    enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
    enrollment.update!(next_due_at: 1.minute.ago)

    described_class.perform_now

    expect(enrollment.touch_occurrence_claims.materialized.count).to eq(1)
  end

  it 'resumes a feature-paused enrollment after the account feature is re-enabled' do
    account = create(:account)
    account.enable_features!('deferred_touch_materialization')
    appointment = create(
      :scheduling_appointment,
      account: account,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
    reminder_group = create(:reminder_group, account: account)
    enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
    account.disable_features!('deferred_touch_materialization')
    Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment).perform
    account.enable_features!('deferred_touch_materialization')

    described_class.perform_now

    expect(enrollment.reload).to be_active
    expect(enrollment.metadata).not_to have_key('paused_reason')
    expect(enrollment.next_due_at).to be_present
  end

  it 'continues with the next candidate after one enrollment fails' do
    first_enrollment = create(:touch_plan_enrollment, next_due_at: 2.minutes.ago)
    second_enrollment = create(:touch_plan_enrollment, next_due_at: 1.minute.ago)
    attempted_ids = []
    exception_tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)
    allow(Reminders::MaterializeEnrollmentStepService).to receive(:new) do |enrollment:|
      instance_double(Reminders::MaterializeEnrollmentStepService).tap do |service|
        allow(service).to receive(:perform) do
          attempted_ids << enrollment.id
          raise 'broken enrollment' if enrollment.id == first_enrollment.id
        end
      end
    end

    described_class.perform_now

    expect(attempted_ids).to eq([first_enrollment.id, second_enrollment.id])
    expect(exception_tracker).to have_received(:capture_exception).once
  end

  it 'chains another batch without retrying failed candidates from the current run' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    enrollments = create_list(:touch_plan_enrollment, 3, next_due_at: 1.minute.ago)
    allow(Reminders::MaterializeEnrollmentStepService).to receive(:new).and_return(
      instance_double(Reminders::MaterializeEnrollmentStepService, perform: nil)
    )

    expect { described_class.perform_now }
      .to have_enqueued_job(described_class).with(1, enrollments.first(2).map(&:id))
  end
end
