class AutomationRules::AppointmentNotificationLeadTime
  MINUTES = 60
  HOLD_RELEASE_GRACE = 15.minutes

  def self.configured_minutes(rule, action: nil)
    return if non_pre_visit_rule?(rule)
    return touch_configured_minutes(rule, action) if touch_action?(action)
    return if mixed_touch_min_minutes?(rule)

    rule_fallback_minutes(rule)
  end

  def self.touch_configured_minutes(rule, action)
    extract_action_minutes(action) || (rule_fallback_minutes(rule) unless any_touch_defines_min_minutes?(rule))
  end

  def self.rule_fallback_minutes(rule)
    rule_minutes = rule&.min_minutes_before_appointment
    rule_minutes if rule_minutes.is_a?(Integer) && rule_minutes.positive?
  end

  def self.short?(appointment, **)
    new(appointment, **).short?
  end

  def self.confirmation_action?(action)
    action_hash = action.to_h.with_indifferent_access
    return true if action_hash[:action_name].to_s == 'send_webhook_event'
    return false unless action_hash[:action_name].to_s == 'create_touch'

    params = Array.wrap(action_hash[:action_params]).first.to_h.with_indifferent_access
    !params[:relative_anchor].to_s.in?(Reminders::MissedAutomationTouchPolicy::APPOINTMENT_ANCHORS)
  end

  def self.explicit_smaller_condition?(rule)
    Array(rule&.conditions).any? do |condition|
      condition = condition.to_h.with_indifferent_access
      next false unless condition[:attribute_key] == 'lead_time_minutes'
      next false unless condition[:filter_operator].in?(%w[equal_to less_than greater_than is_less_than is_greater_than])

      Array.wrap(condition[:values]).any? { |value| value.to_i < MINUTES }
    end
  end

  def self.non_pre_visit_rule?(rule)
    rule&.event_name.present? && AutomationRule::MIN_MINUTES_BEFORE_APPOINTMENT_EVENTS.exclude?(rule.event_name.to_s)
  end

  def self.touch_action?(action)
    action.present? && action.to_h.with_indifferent_access[:action_name].to_s == 'create_touch'
  end

  def self.any_touch_defines_min_minutes?(rule)
    rule_touch_actions(rule).any? { |touch| extract_action_minutes(touch).present? }
  end

  def self.mixed_touch_min_minutes?(rule)
    touches = rule_touch_actions(rule)
    return false if touches.empty?

    touches.map { |touch| extract_action_minutes(touch) }.uniq.length > 1
  end

  def self.rule_touch_actions(rule)
    Array(rule&.actions).select { |entry| touch_action?(entry) }
  end

  def self.extract_action_minutes(action)
    return unless touch_action?(action)

    action_hash = action.to_h.with_indifferent_access
    params = Array.wrap(action_hash[:action_params]).first
    return unless params.is_a?(Hash) || params.respond_to?(:to_h)

    params_hash = params.to_h.with_indifferent_access
    raw = params_hash[AutomationRule::MIN_MINUTES_BEFORE_APPOINTMENT_KEY] ||
          params_hash.dig(:metadata, AutomationRule::MIN_MINUTES_BEFORE_APPOINTMENT_KEY)
    parse_positive_minutes(raw)
  end

  def self.parse_positive_minutes(raw)
    value = case raw
            when Integer
              raw
            when String
              stripped = raw.strip
              stripped.to_i if stripped.match?(/\A\+?\d+\z/)
            end
    value if value && AutomationRule::MIN_MINUTES_BEFORE_APPOINTMENT_RANGE.cover?(value)
  end

  private_class_method :touch_configured_minutes, :rule_fallback_minutes, :non_pre_visit_rule?, :touch_action?, :any_touch_defines_min_minutes?,
                       :mixed_touch_min_minutes?, :rule_touch_actions, :extract_action_minutes, :parse_positive_minutes

  def initialize(appointment, **options)
    @appointment = appointment
    @rule = options[:rule]
    @action = options[:action]
    @event_name = options.key?(:event_name) ? options[:event_name] : @rule&.event_name
    @delayed_notification = options[:delayed_notification] == true
    @enforce_remaining_time = options[:enforce_remaining_time] == true
    @reference_time = options[:reference_time]
    @now = options[:now] || Time.current
  end

  def short?
    return false unless @appointment&.starts_at

    configured = self.class.configured_minutes(@rule, action: @action)
    return configured_short?(configured) if configured.present?

    default_short?
  end

  private

  def configured_short?(minutes)
    return true if @appointment.starts_at <= @now

    ref = effective_reference_time
    return true if @appointment.starts_at - ref < minutes.minutes
    return false if @delayed_notification || !@enforce_remaining_time

    @appointment.starts_at - @now < minutes.minutes
  end

  def effective_reference_time
    return @reference_time if @reference_time.present?
    return @appointment.created_at || @now if @delayed_notification
    return [@appointment.created_at, @now].compact.max if @event_name.to_s == 'appointment_created'

    @now
  end

  def default_short?
    return false unless default_short_applicable?
    return true if @appointment.starts_at <= @now
    return @appointment.starts_at - @appointment.created_at < MINUTES.minutes if @delayed_notification

    @appointment.starts_at - @appointment.created_at < MINUTES.minutes || @appointment.starts_at - @now < MINUTES.minutes
  end

  def default_short_applicable?
    return false unless @event_name.nil? || @event_name.to_s == 'appointment_created'
    return false if @action.present? && !self.class.confirmation_action?(@action)
    return false unless @appointment.starts_at && @appointment.created_at

    !self.class.explicit_smaller_condition?(@rule)
  end
end
