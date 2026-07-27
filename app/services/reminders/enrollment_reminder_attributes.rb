class Reminders::EnrollmentReminderAttributes
  SOURCE_ONLY_KEYS = %w[step_id delay_minutes entity_kind].freeze

  attr_reader :claim, :enrollment, :step

  def initialize(enrollment:, step:, claim:)
    @enrollment = enrollment
    @step = step
    @claim = claim
  end

  def call
    attributes = step.definition.to_h.deep_stringify_keys.except(*SOURCE_ONLY_KEYS)
    attributes = materialize_activation_anchor(attributes)
    attributes['metadata'] = attributes.fetch('metadata', {}).to_h.merge(source_metadata)
    attributes
  end

  private

  def materialize_activation_anchor(attributes)
    return attributes unless attributes['relative_anchor'] == 'touch.created_at'

    attributes.merge(
      'timing_mode' => 'absolute',
      'scheduled_at' => step.due_at,
      'relative_anchor' => nil,
      'relative_offset_seconds' => 0,
      'relative_time_mode' => Reminder::RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME,
      'relative_time_of_day' => nil
    )
  end

  def source_metadata
    {
      'touch_source' => enrollment.metadata['touch_source'],
      'touch_plan_enrollment_id' => enrollment.id,
      'touch_occurrence_claim_id' => claim.id,
      'touch_occurrence_key' => claim.occurrence_key,
      'touch_source_revision' => Reminders::EnrollmentDefinitionResolver.new(enrollment: enrollment).source_revision
    }.compact
  end
end
