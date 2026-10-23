# A touch made by an automation rule never has a send time set by hand. The manual-time flag
# (manual_schedule_override) on a relative timing without a fixed send time makes Reminder#materialize_schedule skip the
# touch, so it would stay a draft without a send time for ever. Rule input therefore never keeps the flag on such a
# timing: a rule save drops it, and a rule saved before that is refused when it runs instead of piling up drafts.
# A relative touch that carries its own send time keeps the flag: there it is a real manual time and the touch is sent.
class AutomationRules::TouchScheduleOverride
  FIELD = 'manual_schedule_override'.freeze
  RUNTIME_ERROR = 'create_touch relative timing cannot use manual_schedule_override; save the automation rule again'.freeze

  def self.relative_with_override?(params)
    return false unless params.is_a?(Hash)

    params = params.with_indifferent_access
    params[:timing_mode].to_s == 'relative' && params[:scheduled_at].blank? && override_set?(params[FIELD])
  end

  def self.without_relative_override(params)
    return params unless relative_with_override?(params)

    params.except(FIELD, FIELD.to_sym)
  end

  # The cast Reminder applies when it saves the flag, so no spelling of "true" gets past this check and freezes a touch.
  def self.override_set?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end
  private_class_method :override_set?
end
