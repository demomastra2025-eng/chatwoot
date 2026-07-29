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

    expect { described_class.perform_now }
      .to have_enqueued_job(Reminders::ProcessPendingRemindersJob)

    expect(enrollment.touch_occurrence_claims.materialized.count).to eq(1)
  end

  context 'with multiple due steps in one enrollment' do
    let(:account) do
      create(:account).tap { |value| value.enable_features!('deferred_touch_materialization') }
    end
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
        entity_kinds: ['appointment'],
        touches: %w[First Second Third].map do |label|
          {
            body: "#{label} due step",
            entity_kind: 'appointment',
            timing_mode: 'relative',
            relative_anchor: 'appointment.starts_at',
            relative_offset_seconds: -1.day.to_i,
            timezone: 'UTC'
          }
        end
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

    before { enrollment }

    it 'materializes all currently due steps and queues processing in one scheduler pass' do
      expect { described_class.perform_now }
        .to have_enqueued_job(Reminders::ProcessPendingRemindersJob)

      expect(enrollment.touch_occurrence_claims.materialized.count).to eq(3)
      expect(account.reminders.where(remindable: appointment).pluck(:body)).to contain_exactly(
        'First due step',
        'Second due step',
        'Third due step'
      )
      expect(enrollment.reload).to be_completed
    end

    it 'bounds a large due backlog and leaves the enrollment ready for the next pass' do
      stub_const("#{described_class}::MAX_DUE_STEPS_PER_ENROLLMENT", 2)
      expect(Rails.logger).to receive(:warn).with(include('Deferred materialization capped'))

      described_class.perform_now

      expect(enrollment.touch_occurrence_claims.materialized.count).to eq(2)
      expect(enrollment.reload).to be_active
      expect(enrollment.next_due_at).to be <= Time.current
    end

    it 'commits earlier steps when a later step fails' do
      next_appointment = create(
        :scheduling_appointment,
        account: account,
        starts_at: appointment.starts_at,
        ends_at: appointment.ends_at
      )
      next_enrollment = Reminders::EnrollGroupService.new(
        account: account,
        reminder_group: reminder_group,
        remindable: next_appointment,
        actor: nil
      ).perform
      first_service = Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment)
      failing_service = instance_double(Reminders::MaterializeEnrollmentStepService)
      allow(failing_service).to receive(:perform).and_raise('broken later step')
      original_constructor = Reminders::MaterializeEnrollmentStepService.method(:new)
      services = [first_service, failing_service]
      allow(Reminders::MaterializeEnrollmentStepService).to receive(:new) do |enrollment:|
        enrollment.id == self.enrollment.id ? services.shift : original_constructor.call(enrollment: enrollment)
      end
      exception_tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)

      described_class.perform_now

      expect(enrollment.touch_occurrence_claims.materialized.count).to eq(1)
      expect(account.reminders.where(remindable: appointment).pluck(:body)).to eq(['First due step'])
      expect(next_enrollment.reload).to be_completed
      expect(exception_tracker).to have_received(:capture_exception).once
    end
  end

  it 'enqueues chained materialization before pending processing' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    enrollment = create(:touch_plan_enrollment, next_due_at: 1.minute.ago)
    create(:touch_plan_enrollment, next_due_at: 1.minute.ago)
    events = []
    service = instance_double(Reminders::MaterializeEnrollmentStepService)
    allow(service).to receive(:perform) do
      events << :materialize
      enrollment.update!(status: 'completed', next_due_at: nil)
    end
    allow(Reminders::MaterializeEnrollmentStepService).to receive(:new).and_return(service)
    allow(described_class).to receive(:perform_later) { events << :chain }
    allow(Reminders::ProcessPendingRemindersJob).to receive(:perform_later) { events << :process }

    described_class.perform_now

    expect(events).to eq(%i[materialize chain process])
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

          enrollment.update!(status: 'completed', next_due_at: nil)
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
    allow(Reminders::MaterializeEnrollmentStepService).to receive(:new) do |enrollment:|
      instance_double(Reminders::MaterializeEnrollmentStepService).tap do |service|
        allow(service).to receive(:perform) { enrollment.update!(status: 'completed', next_due_at: nil) }
      end
    end

    expect { described_class.perform_now }
      .to have_enqueued_job(described_class).with(1, enrollments.first(2).map(&:id))
  end
end
