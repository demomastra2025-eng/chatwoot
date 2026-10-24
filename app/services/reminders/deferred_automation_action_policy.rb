class Reminders::DeferredAutomationActionPolicy
  SUPPORTED_REMINDABLE_TYPES = Reminders::DeferredMaterializationPolicy::ENTITY_ANCHORS.keys.freeze
  # An enrollment is kept once per rule action and record. A reschedule fires again for the same appointment, so a touch
  # timed from the event itself (a legacy delay or touch.created_at) would notify only the first time: the second
  # reschedule finds the completed enrollment. Such an action makes its touch at once instead. A timing anchored on the
  # visit still follows the appointment, and the other events keep their deferral.
  REPEATING_EVENT_NAMES = %w[appointment_rescheduled].freeze
  EVENT_TIME_ANCHORS = %w[touch.created_at].freeze

  attr_reader :account, :definition, :event_name, :remindable

  def initialize(account:, remindable:, definition:, event_name: nil)
    @account = account
    @remindable = remindable
    @definition = Reminders::DefinitionNormalizer.call(definition).with_indifferent_access
    @event_name = event_name.to_s
  end

  def eligible?
    account.feature_enabled?(Reminders::DeferredMaterializationPolicy::FEATURE_NAME) &&
      SUPPORTED_REMINDABLE_TYPES.include?(remindable.class.name) &&
      supported_timing? &&
      single_delivery? &&
      !Reminders::BooleanParam.truthy?(definition[:manual_schedule_override])
  end

  private

  def supported_timing?
    return false if repeating_event_timing?
    return legacy_delay_supported? if legacy_delay?
    return false unless (definition[:timing_mode].presence || 'absolute') == 'relative'

    supported_anchors.include?(definition[:relative_anchor].to_s) && definition[:relative_offset_seconds].present?
  end

  def repeating_event_timing?
    REPEATING_EVENT_NAMES.include?(event_name) &&
      (legacy_delay? || EVENT_TIME_ANCHORS.include?(definition[:relative_anchor].to_s))
  end

  def single_delivery?
    (definition[:repeat_mode].presence || 'once') == 'once' &&
      definition[:post_delivery_action].blank? &&
      definition[:response_action].blank?
  end

  def legacy_delay?
    definition.key?(:delay_minutes) && definition[:timing_mode].blank? && definition[:scheduled_at].blank? &&
      definition[:relative_anchor].blank?
  end

  def legacy_delay_supported?
    Integer(definition[:delay_minutes] || 0) >= 0
  rescue ArgumentError, TypeError
    false
  end

  def supported_anchors
    Reminders::DeferredMaterializationPolicy::ENTITY_ANCHORS.fetch(remindable.class.name) + ['touch.created_at']
  end
end
