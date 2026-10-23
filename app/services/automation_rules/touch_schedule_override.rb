# A touch made by an automation rule never has a send time set by hand. The manual-time flag
# (manual_schedule_override) on a relative timing makes Reminder#materialize_schedule skip the touch, so it would stay
# a draft without a send time for ever. Rule input therefore never keeps the flag on a relative timing: a rule save
# drops it, and a rule saved before that is refused when it runs instead of piling up drafts.
class AutomationRules::TouchScheduleOverride
  FIELD = 'manual_schedule_override'.freeze
  RUNTIME_ERROR = 'create_touch relative timing cannot use manual_schedule_override; save the automation rule again'.freeze

  def self.relative_with_override?(params)
    return false unless params.is_a?(Hash)

    params = params.with_indifferent_access
    params[:timing_mode].to_s == 'relative' && Reminders::BooleanParam.truthy?(params[FIELD])
  end

  def self.without_relative_override(params)
    return params unless relative_with_override?(params)

    params.except(FIELD, FIELD.to_sym)
  end
end
