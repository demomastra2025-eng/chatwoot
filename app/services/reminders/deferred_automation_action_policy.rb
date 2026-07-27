class Reminders::DeferredAutomationActionPolicy
  SUPPORTED_REMINDABLE_TYPES = Reminders::DeferredMaterializationPolicy::ENTITY_ANCHORS.keys.freeze

  attr_reader :account, :definition, :remindable

  def initialize(account:, remindable:, definition:)
    @account = account
    @remindable = remindable
    @definition = Reminders::DefinitionNormalizer.call(definition).with_indifferent_access
  end

  def eligible?
    account.feature_enabled?(Reminders::DeferredMaterializationPolicy::FEATURE_NAME) &&
      SUPPORTED_REMINDABLE_TYPES.include?(remindable.class.name) &&
      supported_timing? &&
      (definition[:repeat_mode].presence || 'once') == 'once' &&
      definition[:post_delivery_action].blank? &&
      !Reminders::BooleanParam.truthy?(definition[:manual_schedule_override])
  end

  private

  def supported_timing?
    return legacy_delay_supported? if legacy_delay?
    return false unless (definition[:timing_mode].presence || 'absolute') == 'relative'

    supported_anchors.include?(definition[:relative_anchor].to_s) && definition[:relative_offset_seconds].present?
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
