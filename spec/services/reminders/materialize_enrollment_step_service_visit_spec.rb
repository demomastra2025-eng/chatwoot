require 'rails_helper'

RSpec.describe Reminders::MaterializeEnrollmentStepService do
  it 'skips a deferred step after the visit moves earlier beyond the shared grace window' do
    account = create(:account).tap { |record| record.enable_features!('deferred_touch_materialization') }
    starts_at = 2.days.from_now
    appointment = create(:scheduling_appointment, account: account, starts_at: starts_at,
                                                  ends_at: starts_at + 30.minutes)
    inbox = create(:inbox, account: account)
    group = create(:reminder_group, account: account, entity_kinds: ['appointment'], touches: [
                     attributes_for(:reminder).slice(:body).merge(entity_kind: 'appointment', timing_mode: 'relative',
                                                                  relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                                                                  target_inbox_id: inbox.id, timezone: 'UTC')
                   ])
    enrollment = Reminders::EnrollGroupService.new(account: account, reminder_group: group,
                                                   remindable: appointment, actor: nil).perform
    moved = 1.hour.from_now
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    claim = described_class.new(enrollment: enrollment.reload, now: Time.current).perform

    expect(claim).to have_attributes(status: 'skipped', last_error: 'missed_due_to_reschedule')
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'cancels a deferred visit-anchored enrollment when rescheduled inside min_minutes_before_appointment' do
    account = create(:account).tap { |record| record.enable_features!('scheduling', 'deferred_touch_materialization') }
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account, phone_number: '+77015554433')
    rule = create(:automation_rule, account: account, event_name: 'appointment_created',
                                    min_minutes_before_appointment: 180, conditions: [],
                                    actions: [{ action_name: 'create_touch', action_params: [{
                                      action_type: 'send_message', content_kind: 'free_text', body: '1h before visit',
                                      timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                                      relative_offset_seconds: -1.hour.to_i, target_inbox_id: inbox.id
                                    }] }])
    starts_at = 2.days.from_now
    appointment = create(:scheduling_appointment, account: account, contact: contact,
                                                  starts_at: starts_at, ends_at: starts_at + 30.minutes)
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    enrollment = account.touch_plan_enrollments.find_by!(remindable: appointment, automation_rule: rule)

    moved = 2.hours.from_now
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    expect(enrollment.reload).to be_cancelled
    expect(enrollment.metadata['cancelled_reason']).to eq(Reminders::StaleAppointmentNoticePolicy::SHORT_LEAD_REASON)
  end

  it 'cancels an active visit-anchored enrollment when min_minutes_before_appointment is raised on a live rule' do
    extend ActiveJob::TestHelper
    account = create(:account).tap { |record| record.enable_features!('scheduling', 'deferred_touch_materialization') }
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account, phone_number: '+77015554434')
    rule = create(:automation_rule, account: account, event_name: 'appointment_created',
                                    min_minutes_before_appointment: 60, conditions: [],
                                    actions: [{ action_name: 'create_touch', action_params: [{
                                      action_type: 'send_message', content_kind: 'free_text', body: '1h before visit',
                                      timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                                      relative_offset_seconds: -1.hour.to_i, target_inbox_id: inbox.id
                                    }] }])
    starts_at = 3.hours.from_now
    appointment = create(:scheduling_appointment, account: account, contact: contact,
                                                  starts_at: starts_at, ends_at: starts_at + 30.minutes)
    appointment.update_columns(created_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations
    AutomationRules::AppointmentActionService.new(rule, account, appointment.reload).perform
    enrollment = account.touch_plan_enrollments.find_by!(remindable: appointment, automation_rule: rule)

    perform_enqueued_jobs { rule.update!(min_minutes_before_appointment: 240) }

    expect(enrollment.reload).to be_cancelled
    expect(enrollment.metadata['cancelled_reason']).to eq(Reminders::StaleAppointmentNoticePolicy::SHORT_LEAD_REASON)
  end

  it 'still materializes a due -2h visit reminder booked days ahead when min_minutes_before_appointment is 180' do
    account = create(:account).tap { |record| record.enable_features!('scheduling', 'deferred_touch_materialization') }
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account, phone_number: '+77015554435')
    rule = create(:automation_rule, account: account, event_name: 'appointment_created',
                                    min_minutes_before_appointment: 180, conditions: [],
                                    actions: [{ action_name: 'create_touch', action_params: [{
                                      action_type: 'send_message', content_kind: 'free_text', body: '2h before visit',
                                      timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                                      relative_offset_seconds: -2.hours.to_i, target_inbox_id: inbox.id
                                    }] }])
    starts_at = 2.days.from_now
    appointment = create(:scheduling_appointment, account: account, contact: contact,
                                                  starts_at: starts_at, ends_at: starts_at + 30.minutes)
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    enrollment = account.touch_plan_enrollments.find_by!(remindable: appointment, automation_rule: rule)

    claim = described_class.new(enrollment: enrollment, now: starts_at - 2.hours + 1.minute).perform

    expect(claim).to be_materialized
    expect(claim.reminder).to be_present
  end
end
