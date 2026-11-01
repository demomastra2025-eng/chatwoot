class Reminders::BackfillAutomationRuleEnrollmentsService
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

  # The release preview and the worker use exactly this selection.
  def plan
    return [] unless backfillable_rule?

    candidate_appointments.find_each.flat_map { |appointment| plan_for(appointment) }
  end

  def perform
    plan.each do |item|
      execute_item(item)
    rescue *TRANSIENT_DATABASE_ERRORS
      raise
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: rule.account).capture_exception
    end
  end

  private

  def execute_item(item)
    appointment = rule.account.scheduling_appointments.find_by(id: item[:appointment_id])
    return unless appointment

    rule.with_lock do
      next unless backfillable_rule?

      appointment.with_lock do
        next unless plan_for(appointment).include?(item)

        action = touch_actions.find { |entry| entry['action_id'] == item[:action_id] }
        if action
          AutomationRules::AppointmentActionService.new(rule, rule.account, appointment).perform(
            actions: [action], raise_errors: true
          )
        end
      end
    end
  end

  def backfillable_rule?
    rule.reload.active? && rule.event_name == SUPPORTED_EVENT_NAME && touch_actions.present?
  end

  def candidate_appointments
    rule.account.scheduling_appointments
        .where.not(status: TERMINAL_APPOINTMENT_STATUSES)
        .where('starts_at > ?', Time.current)
  end

  def plan_for(appointment)
    return [] unless appointment_eligible?(appointment)
    return [] unless AutomationRules::AppointmentConditionService.new(rule, appointment).perform

    touch_actions.filter_map { |action| plan_action(appointment, action) }
  end

  def appointment_eligible?(appointment)
    appointment.starts_at.future? &&
      TERMINAL_APPOINTMENT_STATUSES.exclude?(appointment.status) &&
      !Contact.automation_notifications_suppressed_for?(appointment, account_id: rule.account_id)
  end

  def plan_action(appointment, action)
    definition = touch_definition(action['action_params'])
    return unless Reminders::MissedAutomationTouchPolicy::APPOINTMENT_ANCHORS.include?(definition['relative_anchor'])
    return if AutomationRules::AppointmentNotificationLeadTime.short?(appointment, rule: rule, action: action, now: activation_time)

    probe = Reminders::RelativeScheduleProbe.new(
      account: rule.account, remindable: appointment, definition: definition, created_at: activation_time
    )
    due_at = probe.due_at
    return if due_at.blank? || Reminders::MissedAutomationTouchPolicy.new(reminder: probe.reminder).missed?
    return if already_created?(appointment, action['action_id'])

    kind = deferred?(appointment, definition) ? 'deferred' : 'direct'
    { appointment_id: appointment.id, action_id: action['action_id'], due_at: due_at, kind: kind }
  end

  def already_created?(appointment, action_id)
    enrollment = rule.account.touch_plan_enrollments.where(
      automation_rule: rule, source_action_id: action_id, remindable: appointment
    ).where.not(status: 'cancelled').exists?
    return true if enrollment

    metadata = {
      Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id,
      Reminder::AUTOMATION_ACTION_KEY => action_id
    }
    rule.account.reminders.where(remindable: appointment)
        .where('metadata @> ?', metadata.to_json)
        .exists?(['last_error IS NULL OR last_error NOT IN (?)',
                  %w[automation_rule_inactive automation_rule_deleted automation_action_removed]])
  end

  def deferred?(appointment, definition)
    Reminders::DeferredAutomationActionPolicy.new(
      account: rule.account, remindable: appointment, definition: definition, event_name: rule.event_name
    ).eligible?
  end

  def touch_actions
    rule.actions.select do |raw_action|
      raw_action['action_name'] == 'create_touch' && raw_action['action_id'].present? &&
        touch_definition(raw_action['action_params']).present?
    end
  end

  def touch_definition(action_params)
    definition = action_params.is_a?(Array) ? action_params.first : action_params
    definition.to_h if definition.respond_to?(:to_h)
  end
end
