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
      entity_kinds: ['appointment'],
      touches: [
        attributes_for(:reminder).slice(:body).merge(
          entity_kind: 'appointment',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          timezone: 'UTC'
        )
      ]
    )
  end
  let(:enrollment) do
    account.enable_features!('deferred_touch_materialization', 'scheduling')
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

  it 'rechecks a locked automation rule before materializing a deferred reminder', :aggregate_failures do
    account.enable_features!('deferred_touch_materialization', 'scheduling')
    action_id = SecureRandom.uuid
    definition = reminder_group.touches.first
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      actions: [
        {
          'action_id' => action_id,
          'action_name' => 'create_touch',
          'action_params' => [definition]
        }
      ]
    )
    automation_enrollment = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    ).perform
    service = described_class.new(enrollment: automation_enrollment, now: automation_enrollment.next_due_at + 1.minute)
    expect(service.send(:definition_resolver)).to be_source_available

    rule.update!(active: false)
    service.perform

    expect(automation_enrollment.reload).to be_cancelled
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'locks the automation rule before the enrollment during materialization' do
    account.enable_features!('deferred_touch_materialization', 'scheduling')
    action_id = SecureRandom.uuid
    definition = reminder_group.touches.first
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      actions: [{ 'action_id' => action_id, 'action_name' => 'create_touch', 'action_params' => [definition] }]
    )
    automation_enrollment = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    ).perform
    lock_order = []
    allow(AutomationRule).to receive(:lock).and_wrap_original do |method, *args|
      lock_order << :automation_rule
      method.call(*args)
    end
    allow(automation_enrollment).to receive(:with_lock) do |&block|
      lock_order << :enrollment
      block.call
    end

    described_class.new(
      enrollment: automation_enrollment,
      now: automation_enrollment.next_due_at + 1.minute
    ).perform

    expect(lock_order).to eq(%i[automation_rule enrollment])
  end

  it 'reraises a unique violation that did not create an occurrence claim' do
    service = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute)
    allow(service).to receive(:process_locked_enrollment).and_raise(ActiveRecord::RecordNotUnique)

    expect { service.perform }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'returns the existing occurrence claim after a duplicate claim race' do
    now = enrollment.next_due_at + 1.minute
    claim = described_class.new(enrollment: enrollment, now: now).perform
    service = described_class.new(enrollment: enrollment, now: now)
    service.instance_variable_set(:@occurrence_key, claim.occurrence_key)
    allow(service).to receive(:process_locked_enrollment).and_raise(ActiveRecord::RecordNotUnique)

    expect(service.perform).to eq(claim)
  end

  it 'keeps the materialized reminder executable after the enrollment completes' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    claim.reminder.mark_processing!

    result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

    expect(enrollment.reload).to be_completed
    expect(result).to eq(Reminders::ExecutionScheduleGuard::CONTINUE)
    expect(claim.reminder.reload).to be_processing
  end

  it 'keeps an accepted materialized reminder executable after queue delay' do
    due_at = enrollment.next_due_at
    claim = described_class.new(enrollment: enrollment, now: due_at + 1.minute).perform
    claim.reminder.mark_processing!

    travel_to(due_at + 10.minutes) do
      result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

      expect(result).to eq(Reminders::ExecutionScheduleGuard::CONTINUE)
      expect(claim.reminder.reload).to be_processing
      expect(claim.reload).to be_materialized
    end
  end

  it 'executes a materialized reminder after queue delay when its live definition is unchanged' do
    due_at = enrollment.next_due_at
    claim = described_class.new(enrollment: enrollment, now: due_at + 1.minute).perform
    processing_claim = claim.reminder.mark_processing!
    execution_updated_at = claim.reminder.reload.updated_at
    executed = false

    travel_to(due_at + 10.minutes) do
      result = Reminders::ExecutionLockService.new(
        reminder: claim.reminder,
        processing_claim: processing_claim,
        execution_updated_at: execution_updated_at
      ).perform { executed = true }

      expect(result).to be(true)
      expect(executed).to be(true)
      expect(claim.reminder.reload).to be_processing
    end
  end

  it 'skips a delayed materialized reminder whose live definition moved into the past' do
    due_at = enrollment.next_due_at
    claim = described_class.new(enrollment: enrollment, now: due_at + 1.minute).perform
    reminder_group.update!(
      touches: [reminder_group.touches.first.merge('relative_offset_seconds' => -2.days.to_i)]
    )
    claim.reminder.mark_processing!

    travel_to(due_at + 10.minutes) do
      result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

      expect(result).to eq(Reminders::ExecutionScheduleGuard::STOP)
      expect(claim.reminder.reload).to be_cancelled
      expect(claim.reload).to be_skipped
    end
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

  it 'creates one claim when two workers materialize the same occurrence concurrently' do
    enrollment_id = enrollment.id
    now = enrollment.next_due_at + 1.minute
    barrier = Concurrent::CyclicBarrier.new(2)
    errors = Concurrent::Array.new

    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          worker_enrollment = TouchPlanEnrollment.find(enrollment_id)
          barrier.wait
          described_class.new(enrollment: worker_enrollment, now: now).perform
        rescue StandardError => e
          errors << e
        end
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
    expect(enrollment.touch_occurrence_claims.count).to eq(1)
    expect(account.reminders.where(remindable: appointment).count).to eq(1)
  end

  it 'materializes the current plan text instead of the enrollment snapshot' do
    original_snapshot_body = enrollment.plan_snapshot.first['body']
    reminder_group.update!(touches: [reminder_group.touches.first.merge('body' => 'Current plan text')])

    claim = described_class.new(enrollment: enrollment, now: enrollment.reload.next_due_at + 1.minute).perform

    expect(original_snapshot_body).not_to eq('Current plan text')
    expect(claim.reminder.body).to eq('Current plan text')
  end

  it 'refreshes the live plan definition immediately before delivery' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    reminder_group.update!(touches: [reminder_group.touches.first.merge('body' => 'Latest pre-send text')])
    claim.reminder.mark_processing!

    result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

    expect(result).to eq(Reminders::ExecutionScheduleGuard::CONTINUE)
    expect(claim.reminder.reload.body).to eq('Latest pre-send text')
  end

  it 'does not consume a payload when the final guard refreshes its live definition' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    touch = claim.reminder
    processing_claim = touch.mark_processing!
    execution_updated_at = touch.reload.updated_at
    reminder_group.update!(touches: [reminder_group.touches.first.merge('body' => 'Changed inside final lock')])
    executed = false

    result = Reminders::ExecutionLockService.new(
      reminder: touch,
      processing_claim: processing_claim,
      execution_updated_at: execution_updated_at
    ).perform do
      executed = true
    end

    expect(result).to be_nil
    expect(executed).to be(false)
    expect(touch.reload).not_to be_processing
    expect(touch.body).to eq('Changed inside final lock')
  end

  it 'stops delivery when a live plan edit moves the materialized step into the future' do
    claim = described_class.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    reminder_group.update!(
      touches: [reminder_group.touches.first.merge('relative_offset_seconds' => 1.day.to_i)]
    )
    claim.reminder.mark_processing!

    result = Reminders::ExecutionScheduleGuard.new(reminder: claim.reminder).perform

    expect(result).to eq(Reminders::ExecutionScheduleGuard::STOP)
    expect(claim.reminder.reload).not_to be_processing
    expect(claim.reminder.scheduled_at.to_i).to eq((appointment.starts_at + 1.day).to_i)
  end

  it 'keeps step identity stable when plan steps are reordered' do
    reminder_group.update!(
      touches: [
        reminder_group.touches.first.merge('body' => 'First step'),
        reminder_group.touches.first.except('step_id').merge(
          'body' => 'Second step',
          'relative_offset_seconds' => -23.hours.to_i
        )
      ]
    )
    first_claim = described_class.new(enrollment: enrollment, now: enrollment.reload.next_due_at + 1.minute).perform

    reminder_group.update!(touches: reminder_group.touches.reverse)
    second_claim = described_class.new(enrollment: enrollment, now: enrollment.reload.next_due_at + 1.minute).perform

    expect(first_claim.reminder.body).to eq('First step')
    expect(second_claim.reminder.body).to eq('Second step')
    expect(enrollment.touch_occurrence_claims.count).to eq(2)
    expect(account.reminders.where(remindable: appointment).pluck(:body)).to contain_exactly('First step', 'Second step')
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
