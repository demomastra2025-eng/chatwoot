class Reminders::EnrollmentDefinitionResolver
  attr_reader :enrollment

  def initialize(enrollment:)
    @enrollment = enrollment
  end

  def definitions
    return [] unless source_available?

    raw_definitions.map { |definition| Reminders::DefinitionNormalizer.call(definition) }
  end

  def source_available?
    return enrollment.reminder_group.present? if enrollment.reminder_group_id.present?

    automation_rule&.active? && automation_action.present?
  end

  def source_revision
    source&.updated_at&.iso8601(6)
  end

  private

  def raw_definitions
    if enrollment.reminder_group_id.present?
      return Reminders::ApplicableDefinitions.call(
        definitions: enrollment.reminder_group.touches,
        remindable: enrollment.remindable
      )
    end

    [normalize_automation_params(automation_action.fetch('action_params'))]
  end

  def normalize_automation_params(raw_params)
    params = raw_params.is_a?(Array) ? raw_params.first : raw_params
    params = params.to_h.deep_stringify_keys
    return params unless legacy_delay?(params)

    params.except('delay_minutes').merge(
      'timing_mode' => 'relative',
      'relative_anchor' => 'touch.created_at',
      'relative_offset_seconds' => Integer(params['delay_minutes'] || 0) * 60
    )
  end

  def legacy_delay?(params)
    params.key?('delay_minutes') && params['timing_mode'].blank? && params['scheduled_at'].blank? && params['relative_anchor'].blank?
  end

  def source
    enrollment.reminder_group || automation_rule
  end

  def automation_rule
    @automation_rule ||= enrollment.automation_rule
  end

  def automation_action
    return @automation_action if defined?(@automation_action)

    @automation_action = Array(automation_rule&.actions).find do |action|
      action['action_id'].to_s == enrollment.source_action_id.to_s && action['action_name'].to_s == 'create_touch'
    end
  end
end
