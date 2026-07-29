require 'rails_helper'

RSpec.describe Reminders::BackfillAutomationRuleEnrollmentsJob do
  include ActiveJob::TestHelper

  let(:account) do
    create(:account).tap do |record|
      record.enable_features!('scheduling', 'deferred_touch_materialization')
    end
  end
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:rule) do
    create(
      :automation_rule,
      account: account,
      active: false,
      event_name: 'appointment_created',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ],
      actions: [
        {
          action_name: 'send_webhook_event',
          action_params: ['https://example.com/hooks/appointments']
        },
        {
          action_name: 'create_touch',
          action_params: {
            body: 'Appointment reminder',
            timing_mode: 'relative',
            relative_anchor: 'appointment.starts_at',
            relative_offset_seconds: -1.hour.to_i,
            timezone: 'UTC'
          }
        }
      ]
    )
  end
  let!(:appointment_created_while_disabled) do
    rule
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'scheduled',
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes,
      created_at: 1.minute.ago
    )
  end
  let!(:terminal_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'completed',
      starts_at: 3.days.from_now,
      ends_at: 3.days.from_now + 30.minutes
    )
  end
  let!(:nonmatching_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'confirmed',
      starts_at: 4.days.from_now,
      ends_at: 4.days.from_now + 30.minutes
    )
  end
  let!(:expired_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'scheduled',
      starts_at: 2.hours.ago,
      ends_at: 1.hour.ago
    )
  end
  let!(:stale_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'scheduled',
      starts_at: 5.days.from_now,
      ends_at: 5.days.from_now + 30.minutes,
      created_at: 6.minutes.ago
    )
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'backfills only matching future appointment touch enrollments when the rule is enabled', :aggregate_failures do
    expect(WebhookJob).not_to receive(:perform_later)

    perform_enqueued_jobs do
      rule.update!(active: true)
    end

    enrollment = account.touch_plan_enrollments.find_by!(
      automation_rule: rule,
      remindable: appointment_created_while_disabled
    )
    expect(enrollment).to be_active
    expect(enrollment.source_action_id).to eq(rule.reload.actions.second['action_id'])
    expect(enrollment.next_due_at).to be_within(2.seconds).of(appointment_created_while_disabled.starts_at - 1.hour)
    expect(account.touch_plan_enrollments.where(automation_rule: rule, remindable: terminal_appointment)).to be_empty
    expect(account.touch_plan_enrollments.where(automation_rule: rule, remindable: nonmatching_appointment)).to be_empty
    expect(account.touch_plan_enrollments.where(automation_rule: rule, remindable: expired_appointment)).to be_empty
    expect(account.touch_plan_enrollments.where(automation_rule: rule, remindable: stale_appointment)).to be_empty
    expect(account.reminders.where(remindable: appointment_created_while_disabled)).to be_empty

    claim = Reminders::MaterializeEnrollmentStepService.new(
      enrollment: enrollment,
      now: enrollment.next_due_at + 1.minute
    ).perform
    expect(claim).to be_materialized
    expect(claim.reminder).to have_attributes(
      body: 'Appointment reminder',
      remindable: appointment_created_while_disabled
    )
  end

  it 'is idempotent across retries' do
    rule.update!(active: true)

    2.times { described_class.perform_now(rule.id) }

    expect(
      account.touch_plan_enrollments.where(
        automation_rule: rule,
        remindable: appointment_created_while_disabled
      ).count
    ).to eq(1)
  end

  it 'keeps the backfill window anchored to activation time when the job is delayed' do
    touch_action = rule.actions.second.deep_dup
    touch_action['action_params'] = touch_action['action_params'].merge(
      'relative_anchor' => 'touch.created_at',
      'relative_offset_seconds' => 1.minute.to_i
    )
    rule.update!(actions: [touch_action])
    clear_enqueued_jobs
    rule.update!(active: true)
    activation_time = rule.reload.updated_at
    clear_enqueued_jobs

    travel_to(activation_time + 10.minutes) do
      described_class.perform_now(rule.id, activation_time)

      enrollment = account.touch_plan_enrollments.find_by!(
        automation_rule: rule,
        remindable: appointment_created_while_disabled
      )
      expect(enrollment.activated_at).to eq(activation_time)
      expect(enrollment.next_due_at).to eq(activation_time + 1.minute)

      claim = Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment).perform
      expect(claim).to have_attributes(status: 'skipped', last_error: 'missed_due_to_reschedule')
    end

    expect(account.touch_plan_enrollments.where(automation_rule: rule, remindable: stale_appointment)).to be_empty
    expect(account.reminders.where(remindable: appointment_created_while_disabled)).to be_empty
  end

  it 'ignores a stale activation job after the rule is re-enabled' do
    rule.update!(active: true)
    stale_activation_time = rule.reload.updated_at
    clear_enqueued_jobs

    travel_to(stale_activation_time + 1.minute) do
      rule.update!(active: false)
      rule.update!(active: true)
      clear_enqueued_jobs

      described_class.perform_now(rule.id, stale_activation_time)
    end

    expect(account.touch_plan_enrollments.where(automation_rule: rule)).to be_empty
  end

  it 'retries a transient database failure' do
    rule.update!(active: true)
    clear_enqueued_jobs
    attempts = 0
    service = instance_double(Reminders::BackfillAutomationRuleEnrollmentsService)
    allow(Reminders::BackfillAutomationRuleEnrollmentsService).to receive(:new).and_return(service)
    allow(service).to receive(:perform) do
      attempts += 1
      raise ActiveRecord::Deadlocked if attempts == 1
    end

    perform_enqueued_jobs do
      described_class.perform_later(rule.id)
    end

    expect(attempts).to eq(2)
  end

  it 'recreates an enrollment cancelled by disabling the rule' do
    rule.update!(active: true)
    described_class.perform_now(rule.id)
    original_enrollment = account.touch_plan_enrollments.find_by!(
      automation_rule: rule,
      remindable: appointment_created_while_disabled
    )

    rule.update!(active: false)
    Reminders::ReconcileEnrollmentService.new(enrollment: original_enrollment).perform
    expect(original_enrollment.reload).to be_cancelled

    perform_enqueued_jobs do
      rule.update!(active: true)
    end

    replacement_enrollment = account.touch_plan_enrollments.where(
      automation_rule: rule,
      remindable: appointment_created_while_disabled
    ).order(:id).last
    expect(replacement_enrollment).to be_active
    expect(replacement_enrollment.id).not_to eq(original_enrollment.id)
  end
end
