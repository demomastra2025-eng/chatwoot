require 'rails_helper'

RSpec.describe Reminders::ReconcileSourceEnrollmentsJob do
  let(:account) { create(:account) }
  let(:rule) { create(:automation_rule, account: account, active: false) }

  def automation_reminder(automation_rule, **attributes)
    create(:reminder, { account: automation_rule.account }.merge(attributes)).tap do |reminder|
      reminder.mark_automation_provenance!(automation_rule)
    end
  end

  it 'cancels only unmaterialized open reminders when the automation rule is disabled', :aggregate_failures do
    pending_reminder = automation_reminder(rule)
    processing_reminder = automation_reminder(rule).tap(&:mark_processing!)
    materialized_reminder = automation_reminder(rule).tap do |reminder|
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
    end
    completed_reminder = automation_reminder(rule, status: :completed, completed_at: Time.current)
    other_rule_reminder = automation_reminder(create(:automation_rule, account: account, active: false))

    described_class.perform_now('AutomationRule', rule.id, rule.lifecycle_generation)

    expect(pending_reminder.reload).to have_attributes(
      status: 'cancelled',
      last_error: described_class::AUTOMATION_RULE_DISABLED
    )
    expect(processing_reminder.reload).to have_attributes(
      status: 'cancelled',
      last_error: described_class::AUTOMATION_RULE_DISABLED
    )
    expect(materialized_reminder.reload).to be_processing
    expect(completed_reminder.reload).to be_completed
    expect(other_rule_reminder.reload).to be_pending
  end

  it 'keeps reminders from a newer rule generation when a disable job is delayed', :aggregate_failures do
    rule.update!(active: true)
    stale_reminder = automation_reminder(rule)
    rule.update!(active: false)
    disabled_generation = rule.reload.lifecycle_generation
    rule.update!(active: true)
    new_reminder = automation_reminder(rule)

    described_class.perform_now('AutomationRule', rule.id, disabled_generation)

    expect(stale_reminder.reload).to be_cancelled
    expect(new_reminder.reload).to be_pending
    expect(stale_reminder.metadata[Reminder::AUTOMATION_RULE_GENERATION_KEY]).to eq(disabled_generation)
    expect(new_reminder.metadata[Reminder::AUTOMATION_RULE_GENERATION_KEY]).to eq(disabled_generation + 1)
  end

  it 'rechecks the persisted rule state before creating a reminder', :aggregate_failures do
    rule.update!(active: true)
    conversation = create(:conversation, account: account)
    service = AutomationRules::TouchActionService.new(
      rule: rule,
      account: account,
      record: conversation,
      entity_kind: 'conversation'
    )

    rule.update!(active: false)
    expect(service.create_touch([{ body: 'Do not send', delay_minutes: 10 }])).to be_nil

    rule.update!(active: true)
    expect(service.create_touch([{ body: 'Still stale', delay_minutes: 10 }])).to be_nil
    reminder = AutomationRules::TouchActionService.new(
      rule: rule.reload,
      account: account,
      record: conversation,
      entity_kind: 'conversation'
    ).create_touch([{ body: 'Send later', delay_minutes: 10 }])

    expect(account.reminders.where(remindable: conversation).count).to eq(1)
    expect(reminder).to be_pending
    expect(reminder.metadata[Reminder::AUTOMATION_RULE_GENERATION_KEY]).to eq(rule.reload.lifecycle_generation)
  end

  it 'cancels only the disabled deferred generation after a delayed disable job', :aggregate_failures do
    account.enable_features!('deferred_touch_materialization', 'scheduling')
    appointment = create(:scheduling_appointment, account: account, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
    action_id = SecureRandom.uuid
    definition = {
      body: 'Appointment reminder',
      entity_kind: 'appointment',
      timing_mode: 'relative',
      relative_anchor: 'appointment.starts_at',
      relative_offset_seconds: -1.day.to_i,
      timezone: 'UTC'
    }
    automation_rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      actions: [{ action_id: action_id, action_name: 'create_touch', action_params: [definition] }]
    )
    old_enrollment = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: automation_rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    ).perform

    automation_rule.update!(active: false)
    disabled_generation = automation_rule.lifecycle_generation
    automation_rule.update!(active: true)
    new_enrollment = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: automation_rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    ).perform

    described_class.perform_now('AutomationRule', automation_rule.id, disabled_generation)
    Reminders::MaterializeEnrollmentStepService.new(
      enrollment: old_enrollment,
      now: old_enrollment.next_due_at + 1.minute
    ).perform

    expect(old_enrollment.reload).to be_cancelled
    expect(new_enrollment.reload).to be_active
    expect(new_enrollment.source_generation).to eq(disabled_generation + 1)
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'reraises deferred cancellation failures so the job is retried' do
    enrollment = create(
      :touch_plan_enrollment,
      account: account,
      automation_rule: rule,
      reminder_group: nil,
      remindable: create(:scheduling_appointment, account: account),
      source_action_id: 'action-1',
      source_generation: rule.lifecycle_generation,
      plan_snapshot: [{ body: 'Deferred reminder' }],
      plan_digest: Digest::SHA256.hexdigest('Deferred reminder')
    )
    allow(Reminders::CancelEnrollmentService).to receive(:new).with(
      enrollment: enrollment,
      reason: described_class::AUTOMATION_RULE_DISABLED,
      metadata: { 'automation_rule_generation' => rule.lifecycle_generation }
    ).and_raise(ActiveRecord::Deadlocked)

    expect do
      described_class.perform_now('AutomationRule', rule.id, rule.lifecycle_generation)
    end.to raise_error(ActiveRecord::Deadlocked)
  end

  it 'is enqueued when the automation rule is toggled' do
    rule.update!(active: true)

    expect do
      rule.update!(active: false)
    end.to have_enqueued_job(described_class)
      .with('AutomationRule', rule.id, kind_of(Integer))
      .on_queue('scheduled_jobs')
  end
end
