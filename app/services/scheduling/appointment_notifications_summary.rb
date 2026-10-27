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
    account.reminders.where(remindable: appointment).order(:scheduled_at, :id).map do |reminder|
      {
        id: reminder.id, status: reminder.status, scheduled_at: reminder.scheduled_at,
        completed_at: reminder.completed_at, reason: reminder.last_error,
        delivery_stage: reminder.delivery_stage,
        action_id: reminder.metadata.to_h[Reminder::AUTOMATION_ACTION_KEY]
      }
    end
  end

  def append_enrollments(items)
    visible_actions = items.filter_map { |item| item[:action_id] }
    account.touch_plan_enrollments.where(remindable: appointment, status: 'active').find_each do |enrollment|
      next if visible_actions.include?(enrollment.source_action_id)

      items << {
        id: "enrollment-#{enrollment.id}", status: 'pending', scheduled_at: enrollment.next_due_at,
        action_id: enrollment.source_action_id
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
