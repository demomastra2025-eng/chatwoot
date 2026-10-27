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
    rule_names = names_for(reminders)
    messages = messages_for(reminders)
    reminders.map { |reminder| reminder_payload(reminder, rule_names, messages) }
  end

  def names_for(reminders)
    rule_ids = reminders.filter_map { |reminder| reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY] }.uniq
    account.automation_rules.where(id: rule_ids).pluck(:id, :name).to_h
  end

  def messages_for(reminders)
    message_ids = reminders.filter_map { |reminder| reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY] }.uniq
    account.messages.where(id: message_ids).pluck(:id, :conversation_id, :status).each_with_object({}) do |(id, conversation_id, status), found|
      found[id] = { conversation_id: conversation_id, status: Message.statuses.key(status) || status }
    end
  end

  def reminder_payload(reminder, rule_names, messages)
    metadata = reminder.metadata.to_h
    rule_id = metadata[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    message_id = metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_i
    message = messages[message_id]
    {
      id: reminder.id, status: reminder.status, scheduled_at: reminder.scheduled_at,
      completed_at: reminder.completed_at, reason: reminder.last_error,
      delivery_stage: reminder.delivery_stage,
      action_id: metadata[Reminder::AUTOMATION_ACTION_KEY], rule_name: rule_names[rule_id.to_i],
      message_id: message ? message_id : nil, conversation_id: message&.fetch(:conversation_id), message_status: message&.fetch(:status)
    }
  end

  def append_enrollments(items)
    visible_actions = items.filter_map { |item| item[:action_id] }
    enrollments = account.touch_plan_enrollments.where(remindable: appointment, status: 'active').to_a
    names = account.automation_rules.where(id: enrollments.map(&:automation_rule_id)).pluck(:id, :name).to_h
    enrollments.each do |enrollment|
      next if visible_actions.include?(enrollment.source_action_id)

      items << {
        id: "enrollment-#{enrollment.id}", status: 'pending', scheduled_at: enrollment.next_due_at,
        action_id: enrollment.source_action_id, rule_name: names[enrollment.automation_rule_id]
      }
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
