# frozen_string_literal: true

require 'json'

class Reminders::NotificationsReleaseService
  def retime_open
    automation_source = "metadata ->> 'touch_source' = 'automation' OR metadata ->> 'post_delivery_audit_source' = 'automation'"
    scope = editable_reminders(Reminder.open_statuses).where(remindable_type: 'Scheduling::Appointment')
                                                      .where(relative_anchor: Reminders::MissedAutomationTouchPolicy::APPOINTMENT_ANCHORS)
                                                      .where(automation_source)
    preview = reminder_scope_lines(scope)
    return preview unless apply?

    backup!('retime_open', scope.find_each)
    scope.distinct.pluck(:remindable_id).each do |appointment_id|
      appointment = Scheduling::Appointment.find_by(id: appointment_id)
      Reminders::RetimeVisitTouchesService.new(appointment: appointment).perform if appointment
    end
    preview
  end

  def cancel_inactive_rule_reminders
    inactive_rule = 'NOT EXISTS (SELECT 1 FROM automation_rules WHERE automation_rules.id = ' \
                    "(reminders.metadata ->> 'post_delivery_automation_rule_id')::bigint AND automation_rules.active)"
    affected = editable_reminders(Reminder.open_statuses).where("metadata ? 'post_delivery_automation_rule_id'")
                                                         .where(inactive_rule)
    preview = reminder_scope_lines(affected)
    return preview unless apply?

    backup!('cancel_inactive_rule_reminders', affected)
    affected.distinct.pluck(:account_id, Arel.sql("metadata ->> 'post_delivery_automation_rule_id'"))
            .each { |account_id, rule_id| cancel_unavailable_rule(account_id, rule_id) }
    preview
  end

  def backfill_rule
    account = Account.find(ENV.fetch('ACCOUNT_ID'))
    rule = account.automation_rules.find(ENV.fetch('RULE_ID'))
    service = Reminders::BackfillAutomationRuleEnrollmentsService.new(rule: rule, activation_time: rule.updated_at)
    items = service.plan
    preview = ["account_id=#{account.id} count=#{items.size} appointment_ids=#{items.pluck(:appointment_id).join(',')}"]
    return preview unless apply?

    backup!('backfill_rule', [])
    service.perform
    preview
  end

  def normalize_rules
    changed = AutomationRule.where(event_name: AutomationRule::APPOINTMENT_EVENT_NAMES).find_each.filter_map do |rule|
      rule.valid?
      rule if rule.will_save_change_to_actions?
    end
    preview = group_lines(changed, id_method: :id, label: 'rule_ids')
    return preview unless apply?

    backup!('normalize_rules', [])
    changed.each(&:save!)
    preview
  end

  private

  def editable_reminders(scope)
    scope.where("reminders.status <> 'processing' OR reminders.metadata ->> ? IS NULL",
                Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY)
  end

  def apply?
    return false unless ENV['APPLY'] == '1'

    backup_dir = ENV.fetch('BACKUP_DIR', nil)
    unless ENV['CONFIRM'] == 'yes' && backup_dir.present? && File.directory?(backup_dir)
      raise ArgumentError, 'Apply requires CONFIRM=yes and an existing BACKUP_DIR'
    end

    true
  end

  def backup!(task, reminders)
    rows = reminders.map do |reminder|
      { id: reminder.id, status: reminder.status, scheduled_at: reminder.scheduled_at, last_error: reminder.last_error }
    end
    path = File.join(ENV.fetch('BACKUP_DIR'), "#{task}-#{Time.current.utc.strftime('%Y%m%d%H%M%S%6N')}.json")
    File.write(path, JSON.pretty_generate(rows))
  end

  def group_lines(records, id_method:, label: 'reminder_ids')
    records.group_by(&:account_id).map do |account_id, items|
      "account_id=#{account_id} count=#{items.size} #{label}=#{items.map { |item| item.public_send(id_method) }.join(',')}"
    end
  end

  def reminder_scope_lines(scope)
    scope.group(:account_id).count.map do |account_id, count|
      "account_id=#{account_id} count=#{count} reminder_ids=#{scope.where(account_id: account_id).pluck(:id).join(',')}"
    end
  end

  def cancel_unavailable_rule(account_id, rule_id)
    rule = AutomationRule.find_by(id: rule_id, account_id: account_id)
    Reminders::CancelRuleTouchesService.new(
      rule: rule, account: Account.find(account_id), rule_id: rule_id,
      reason: rule ? 'automation_rule_inactive' : 'automation_rule_deleted'
    ).perform
  end
end
