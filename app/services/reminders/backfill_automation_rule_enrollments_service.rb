class Reminders::BackfillAutomationRuleEnrollmentsService
  BACKFILL_WINDOW = 5.minutes
  SUPPORTED_EVENT_NAME = 'appointment_created'.freeze
  TERMINAL_APPOINTMENT_STATUSES = %w[cancelled completed no_show].freeze
  TRANSIENT_DATABASE_ERRORS = [
    ActiveRecord::ConnectionTimeoutError,
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout
  ].freeze

  attr_reader :activation_time, :rule

  def initialize(rule:, activation_time:)
    @rule = rule
    @activation_time = activation_time
  end

  def perform
    return unless backfillable_rule?

    candidate_appointments.find_each do |appointment|
      result = backfill_appointment(appointment)
      break if result == :source_unavailable
    rescue *TRANSIENT_DATABASE_ERRORS
      raise
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: rule.account).capture_exception
    end
  end

  private

  def backfillable_rule?
    rule.active? && rule.event_name == SUPPORTED_EVENT_NAME && touch_actions.present?
  end

  def candidate_appointments
    rule.account.scheduling_appointments
        .where.not(status: TERMINAL_APPOINTMENT_STATUSES)
        .where('ends_at > ?', Time.current)
        .where(created_at: (activation_time - BACKFILL_WINDOW)..activation_time)
  end

  def backfill_appointment(appointment)
    source_available = true
    rule.with_lock do
      source_available = backfillable_rule?
      next unless source_available

      appointment.with_lock do
        next unless appointment_eligible?(appointment)
        next unless AutomationRules::AppointmentConditionService.new(rule, appointment).perform

        deferred_touch_actions(appointment).each do |action|
          enroll_action(appointment, action)
        end
      end
    end
    :source_unavailable unless source_available
  end

  def appointment_eligible?(appointment)
    appointment.ends_at.future? && TERMINAL_APPOINTMENT_STATUSES.exclude?(appointment.status)
  end

  def touch_actions
    rule.actions.filter_map do |raw_action|
      action = raw_action.to_h.with_indifferent_access
      next unless action[:action_name] == 'create_touch' && action[:action_id].present?

      definition = touch_definition(action[:action_params])
      next if definition.blank?

      action
    end
  end

  def deferred_touch_actions(appointment)
    touch_actions.select do |action|
      Reminders::DeferredAutomationActionPolicy.new(
        account: rule.account,
        remindable: appointment,
        definition: touch_definition(action[:action_params])
      ).eligible?
    end
  end

  def enroll_action(appointment, action)
    Reminders::EnrollAutomationActionService.new(
      account: rule.account,
      rule: rule,
      action_id: action[:action_id],
      remindable: appointment,
      definition: touch_definition(action[:action_params])
    ).perform(activated_at: activation_time)
  end

  def touch_definition(action_params)
    definition = action_params.is_a?(Array) ? action_params.first : action_params
    definition.to_h if definition.respond_to?(:to_h)
  end
end
