class SchedulingAutomationRuleListener < BaseListener
  def appointment_created(event)
    process_appointment_event(event, 'appointment_created')
  end

  def appointment_updated(event)
    process_appointment_event(event, 'appointment_updated')
  end

  def appointment_cancelled(event)
    process_appointment_event(event, 'appointment_cancelled')
  end

  def appointment_completed(event)
    process_appointment_event(event, 'appointment_completed')
  end

  private

  def process_appointment_event(event, event_name)
    return if performed_by_automation?(event)

    appointment, account = extract_appointment_and_account(event)
    return unless appointment.present? && account.present?

    matching_rules_for_event(event_name, account, appointment, event.data[:changed_attributes]).each do |rule|
      live_appointment = account.scheduling_appointments.find_by(id: appointment.id)
      next if live_appointment.blank?

      AutomationRules::AppointmentActionService.new(
        rule,
        account,
        live_appointment,
        changed_attributes: event.data[:changed_attributes]
      ).perform
    end
  end

  def matching_rules_for_event(event_name, account, appointment, changed_attributes)
    snapshot = appointment_snapshot(account, appointment)

    current_account_rules(event_name, account).filter_map do |rule|
      conditions_match = AutomationRules::AppointmentConditionService.new(
        rule,
        snapshot,
        changed_attributes: changed_attributes
      ).perform

      rule if conditions_match
    end
  end

  def current_account_rules(event_name, account)
    AutomationRule.where(
      event_name: event_name,
      account_id: account.id,
      active: true
    )
  end

  def performed_by_automation?(event)
    event.data[:performed_by].present? && event.data[:performed_by].instance_of?(AutomationRule)
  end

  def appointment_snapshot(account, appointment)
    account.scheduling_appointments.find_by(id: appointment.id) || appointment
  end
end
