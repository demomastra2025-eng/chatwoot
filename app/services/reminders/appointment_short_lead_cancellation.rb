# frozen_string_literal: true

class Reminders::AppointmentShortLeadCancellation
  SHORT_LEAD_REASON = Reminders::StaleAppointmentNoticePolicy::SHORT_LEAD_REASON
  CANCELLED_VIA = 'appointment_short_lead_time'
  OPEN_TOUCH_STATUSES = %w[draft pending].freeze

  def self.cancel_reminder_if_short!(reminder, rescheduled: false, rule: nil, now: Time.current)
    new(now: now).cancel_reminder_if_short!(reminder, rescheduled: rescheduled, rule: rule)
  end

  def self.cancel_enrollment_if_short!(enrollment, rescheduled: false, now: Time.current)
    new(now: now).cancel_enrollment_if_short!(enrollment, rescheduled: rescheduled)
  end

  def self.cancel_open_rule_touches!(rule, now: Time.current)
    new(now: now).cancel_open_rule_touches!(rule)
  end

  def initialize(now: Time.current)
    @now = now
  end

  def cancel_reminder_if_short!(reminder, rescheduled: false, rule: nil)
    return false unless cancellable_reminder?(reminder)

    appointment = reminder.remindable
    resolved_rule = rule || resolve_rule_for_reminder(reminder, appointment)
    action = find_rule_action(resolved_rule, reminder.metadata.to_h[Reminder::AUTOMATION_ACTION_KEY])
    return false unless short_configured_lead?(appointment, resolved_rule, action, reminder.created_at, rescheduled)

    cancel_reminder_and_claims!(reminder)
  end

  def cancel_enrollment_if_short!(enrollment, rescheduled: false)
    return false if enrollment.cancelled? || !appointment_with_start?(enrollment.remindable)

    appointment = enrollment.remindable
    rule = resolve_rule_for_enrollment(enrollment)
    action = find_rule_action(rule, enrollment.source_action_id)
    return false unless short_configured_lead?(appointment, rule, action, enrollment.created_at, rescheduled)

    Reminders::CancelEnrollmentService.new(
      enrollment: enrollment,
      reason: SHORT_LEAD_REASON,
      metadata: { 'cancelled_via' => CANCELLED_VIA, 'evaluated_at' => @now.iso8601 }
    ).perform
    true
  end

  def cancel_open_rule_touches!(rule)
    return 0 unless rule_has_configured_min_minutes?(rule)

    cancelled = 0
    open_appointment_touches(rule).find_each do |reminder|
      cancelled += 1 if cancel_reminder_if_short!(reminder, rule: rule)
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: rule.account).capture_exception
    end
    cancelled
  end

  private

  def cancellable_reminder?(reminder)
    Reminder::OPEN_STATUSES.include?(reminder.status) &&
      !reminder.delivery_materialized? &&
      appointment_with_start?(reminder.remindable)
  end

  def appointment_with_start?(record)
    record.is_a?(Scheduling::Appointment) && record.starts_at.present?
  end

  def short_configured_lead?(appointment, rule, action, record_created_at, rescheduled)
    return false if rule.blank?
    return false if AutomationRules::AppointmentNotificationLeadTime.configured_minutes(rule, action: action).blank?

    ref = reference_time_for(appointment, rule, action, record_created_at, rescheduled)
    AutomationRules::AppointmentNotificationLeadTime.short?(
      appointment,
      rule: rule,
      action: action,
      reference_time: ref,
      now: @now
    )
  end

  def reference_time_for(appointment, rule, action, record_created_at, rescheduled)
    return @now if rescheduled

    [appointment.created_at, record_created_at, rule.min_minutes_updated_at(action: action)].compact.max || @now
  end

  def cancel_reminder_and_claims!(reminder)
    reminder.cancel!(SHORT_LEAD_REASON)
    return false unless reminder.reload.cancelled?

    TouchOccurrenceClaim.where(reminder_id: reminder.id).where.not(status: 'skipped').find_each do |claim|
      claim.update!(status: 'skipped', last_error: SHORT_LEAD_REASON)
    end
    true
  end

  def resolve_rule_for_reminder(reminder, appointment)
    metadata = reminder.metadata.to_h
    rule_id = metadata['automation_rule_id'] || metadata[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    return if rule_id.blank?

    AutomationRule.find_by(id: rule_id, account_id: appointment.account_id)
  end

  def resolve_rule_for_enrollment(enrollment)
    enrollment.automation_rule || AutomationRule.find_by(id: enrollment.automation_rule_id, account_id: enrollment.account_id)
  end

  def find_rule_action(rule, raw_action_key)
    raw_key = raw_action_key.to_s
    return if rule.blank? || raw_key.blank?

    stripped_key = raw_key.delete_prefix("#{rule.id}:")
    Array(rule.actions).find do |entry|
      candidate = entry.to_h['action_id'].to_s
      candidate.present? && (candidate == raw_key || candidate == stripped_key)
    end
  end

  def rule_has_configured_min_minutes?(rule)
    return false unless rule.is_a?(AutomationRule) && rule.min_minutes_before_appointment_event?
    return true if rule.min_minutes_before_appointment.present?

    Array(rule.actions).any? do |action|
      AutomationRules::AppointmentNotificationLeadTime.configured_minutes(rule, action: action).present?
    end
  end

  def open_appointment_touches(rule)
    rule.account.reminders.where(status: OPEN_TOUCH_STATUSES, remindable_type: 'Scheduling::Appointment').where(
      'metadata @> :own OR metadata @> :provenance',
      own: { 'automation_rule_id' => rule.id }.to_json,
      provenance: { Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id }.to_json
    )
  end
end
