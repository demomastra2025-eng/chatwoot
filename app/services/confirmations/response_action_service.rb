# frozen_string_literal: true

class Confirmations::ResponseActionService
  def initialize(confirmation_request:, decision:)
    @confirmation_request = confirmation_request
    @decision = decision.to_s
  end

  def perform
    return 'not_configured' if reminder.blank? || reminder.response_action.blank?
    return 'decision_recorded' unless decision == 'confirmed'

    case reminder.response_action
    when Reminder::RESPONSE_ACTION_CONFIRM_APPOINTMENT
      confirm_appointment!
    else
      raise ArgumentError, "Unsupported confirmation response action: #{reminder.response_action}"
    end
  end

  private

  attr_reader :confirmation_request, :decision

  def reminder
    @reminder ||= confirmation_request.reminder
  end

  def appointment
    @appointment ||= confirmation_request.subject
  end

  def confirm_appointment!
    validate_appointment_context!

    appointment.with_lock do
      appointment.reload
      next 'already_confirmed' if appointment.status == 'confirmed'
      next 'subject_not_confirmable' unless appointment.status == 'scheduled'

      with_automation_actor do
        Scheduling::Appointments::MutationGuard.ensure_assignable!({ status: 'confirmed' })
        appointment.update!(status: 'confirmed')
      end
      'appointment_confirmed'
    end
  end

  def validate_appointment_context!
    unless appointment.is_a?(Scheduling::Appointment) &&
           reminder.remindable == appointment &&
           appointment.account_id == confirmation_request.account_id
      raise ArgumentError, 'Confirmation response appointment does not match its originating touch'
    end
  end

  def with_automation_actor
    previous_actor = Current.executed_by
    Current.executed_by = automation_rule
    yield
  ensure
    Current.executed_by = previous_actor
  end

  def automation_rule
    return unless reminder.metadata.to_h[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'

    rule_id = reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    confirmation_request.account.automation_rules.find_by(id: rule_id)
  end
end
