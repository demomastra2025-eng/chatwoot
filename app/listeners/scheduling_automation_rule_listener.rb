class SchedulingAutomationRuleListener < BaseListener
  RESCHEDULED_ATTRIBUTE_KEYS = %w[starts_at resource_id].freeze

  def appointment_created(event)
    return if performed_by_automation?(event)

    appointment, account = extract_appointment_and_account(event)
    return if appointment.blank? || account.blank?

    rules = matching_rules_for_event('appointment_created', account, appointment, event.data[:changed_attributes])
    dispatch_created_rules(rules, account, appointment, event)
  end

  def appointment_updated(event)
    process_appointment_event(event, 'appointment_updated')
    return unless appointment_rescheduled?(event)

    process_appointment_event(event, 'appointment_rescheduled')
    process_move_to_another_day(event)
  end

  def appointment_cancelled(event)
    process_appointment_event(event, 'appointment_cancelled')
  end

  def appointment_completed(event)
    process_appointment_event(event, 'appointment_completed')
  end

  def appointment_no_show(event)
    process_appointment_event(event, 'appointment_no_show')
  end

  private

  def dispatch_created_rules(rules, account, appointment, event)
    held = AutomationRules::AppointmentCreatedNotificationHold.required?(appointment, performed_by: event.data[:performed_by])
    held_rules = held ? AutomationRules::AppointmentCreatedNotificationHold.holdable_rules(appointment, rules) : []

    AutomationRules::AppointmentCreatedNotificationHold.record!(appointment, held_rules) if held_rules.any?
    execute_created_rules(rules, account, appointment, event.data[:changed_attributes], held)
    enqueue_held_release(appointment) if held_rules.any?
  end

  def enqueue_held_release(appointment)
    command_id = appointment.reload.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY]
    AutomationRules::ReleaseAppointmentCreatedNotificationsJob.perform_later(command_id) if command_id.present?
  end

  def execute_created_rules(rules, account, appointment, changed_attributes, held)
    rules.each do |rule|
      live_appointment = account.scheduling_appointments.find_by(id: appointment.id)
      next if live_appointment.blank?

      service = AutomationRules::AppointmentActionService.new(
        rule, account, live_appointment, changed_attributes: changed_attributes
      )
      if held
        service.perform(actions: AutomationRules::AppointmentCreatedNotificationHold.other_actions(rule))
      else
        service.perform
      end
    end
  end

  def appointment_rescheduled?(event)
    event.data[:changed_attributes].to_h.keys.intersect?(RESCHEDULED_ATTRIBUTE_KEYS)
  end

  # The appointment model drops the confirmation of a visit that moves to another day; the rules that plan the reminders of a
  # booking plan them again for the new date.
  def process_move_to_another_day(event)
    return if performed_by_automation?(event)

    appointment, account = extract_appointment_and_account(event)
    return unless appointment.present? && account.present?

    live_appointment = account.scheduling_appointments.find_by(id: appointment.id)
    previous_starts_at = event.data[:changed_attributes].to_h['starts_at']&.first
    return unless live_appointment&.moved_to_another_day_from?(previous_starts_at)

    AutomationRules::AppointmentMovedToAnotherDayService.new(
      account: account,
      appointment: live_appointment,
      rules: matching_rules_for_event('appointment_created', account, live_appointment, nil)
    ).perform
  end

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
