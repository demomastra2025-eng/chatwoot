class Scheduling::AppointmentNotificationsSummary
  def initialize(account:, appointment:)
    @account = account
    @appointment = appointment
  end

  def perform
    items = reminder_items
    append_enrollments(items)
    append_unmaterialized_claims(items)
    items
  end

  private

  attr_reader :account, :appointment

  def reminder_items
    reminders = account.reminders.where(remindable: appointment).order(:scheduled_at, :id).to_a
    rules = rules_for(reminders)
    messages = messages_for(reminders)
    reminders.map { |reminder| reminder_payload(reminder, rules, messages) }
  end

  def rules_for(reminders)
    rule_ids = reminders.filter_map { |reminder| reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY] }.uniq
    account.automation_rules.where(id: rule_ids).index_by(&:id)
  end

  def messages_for(reminders)
    message_ids = reminders.filter_map { |reminder| reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY] }.uniq
    account.messages.where(id: message_ids).pluck(:id, :conversation_id, :status).each_with_object({}) do |(id, conversation_id, status), found|
      found[id] = { conversation_id: conversation_id, status: Message.statuses.key(status) || status }
    end
  end

  def reminder_payload(reminder, rules, messages)
    metadata = reminder.metadata.to_h
    rule = rules[metadata[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY].to_i]
    action_id = metadata[Reminder::AUTOMATION_ACTION_KEY]
    message_id = metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_i
    message = messages[message_id]
    {
      id: reminder.id, status: reminder.status, scheduled_at: reminder.scheduled_at,
      completed_at: reminder.completed_at, reason: reminder.last_error,
      delivery_stage: reminder.delivery_stage,
      action_id: action_id, rule_name: rule&.name,
      min_minutes_before_appointment: configured_min_minutes(rule, action_id),
      message_id: message ? message_id : nil, conversation_id: message&.fetch(:conversation_id), message_status: message&.fetch(:status)
    }
  end

  def append_enrollments(items)
    visible_actions = items.filter_map { |item| item[:action_id] }
    enrollments = account.touch_plan_enrollments.where(remindable: appointment, status: 'active').to_a
    rules = account.automation_rules.where(id: enrollments.map(&:automation_rule_id)).index_by(&:id)
    enrollments.each do |enrollment|
      next if visible_actions.include?(enrollment.source_action_id)

      rule = rules[enrollment.automation_rule_id]
      items << {
        id: "enrollment-#{enrollment.id}", status: 'pending', scheduled_at: enrollment.next_due_at,
        action_id: enrollment.source_action_id, rule_name: rule&.name,
        min_minutes_before_appointment: configured_min_minutes(rule, enrollment.source_action_id)
      }
    end
  end

  def configured_min_minutes(rule, raw_action_key)
    return if rule.blank?

    matching_action = find_rule_action(rule, raw_action_key)
    AutomationRules::AppointmentNotificationLeadTime.configured_minutes(rule, action: matching_action)
  end

  def find_rule_action(rule, raw_action_key)
    raw_key = raw_action_key.to_s
    return if raw_key.blank?

    stripped_key = raw_key.delete_prefix("#{rule.id}:")
    Array(rule.actions).find do |entry|
      candidate = entry.to_h['action_id'].to_s
      candidate.present? && (candidate == raw_key || candidate == stripped_key)
    end
  end

  def append_unmaterialized_claims(items)
    account.touch_occurrence_claims.joins(:touch_plan_enrollment)
           .where(touch_plan_enrollments: { remindable_type: 'Scheduling::Appointment', remindable_id: appointment.id })
           .where(status: %w[skipped failed], reminder_id: nil).find_each do |claim|
      items << {
        id: "claim-#{claim.id}", status: claim.status, scheduled_at: claim.due_at, reason: claim.last_error
      }
    end
  end
end
