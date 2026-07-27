class Reminders::DeferredMaterializationPolicy
  FEATURE_NAME = 'deferred_touch_materialization'.freeze
  ENTITY_ANCHORS = {
    'Scheduling::Appointment' => %w[appointment.created_at appointment.starts_at appointment.ends_at],
    'Crm::Deal' => %w[deal.created_at deal.expected_close_on]
  }.freeze

  attr_reader :account, :remindable, :reminder_group

  def initialize(account:, remindable:, reminder_group:)
    @account = account
    @remindable = remindable
    @reminder_group = reminder_group
  end

  def eligible?
    account.feature_enabled?(FEATURE_NAME) &&
      ENTITY_ANCHORS.key?(remindable.class.name) &&
      reminder_group.entity_kind_supported?(entity_kind) &&
      definitions.present? && definitions.all? { |definition| supported_definition?(definition) }
  end

  private

  def definitions
    @definitions ||= reminder_group.touches.map { |definition| Reminders::DefinitionNormalizer.call(definition) }
  end

  def supported_definition?(definition)
    params = definition.with_indifferent_access
    (params[:timing_mode].presence || 'absolute') == 'relative' &&
      (params[:repeat_mode].presence || 'once') == 'once' &&
      params[:post_delivery_action].blank? &&
      ENTITY_ANCHORS.fetch(remindable.class.name).include?(params[:relative_anchor].to_s)
  end

  def entity_kind
    remindable.is_a?(Scheduling::Appointment) ? 'appointment' : 'deal'
  end
end
