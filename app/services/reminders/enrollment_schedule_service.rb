class Reminders::EnrollmentScheduleService
  Step = Struct.new(:definition, :due_at, :index, :occurrence_key, :step_key, keyword_init: true)

  attr_reader :enrollment

  def initialize(enrollment:)
    @enrollment = enrollment
  end

  def pending_steps
    claimed_keys = enrollment.touch_occurrence_claims.pluck(:occurrence_key).to_set
    current_steps.reject { |step| claimed_keys.include?(step.occurrence_key) }.sort_by { |step| [step.due_at, step.index] }
  end

  def current_steps
    materialized_steps
  end

  def next_step
    pending_steps.first
  end

  def refresh_next_due!
    step = next_step
    next_status = if step
                    enrollment.paused? ? 'paused' : 'active'
                  else
                    'completed'
                  end
    enrollment.update!(status: next_status, next_due_at: step&.due_at)
    step
  end

  def terminal_remindable?
    remindable = enrollment.remindable
    return true if remindable.blank?
    return false if enrollment.metadata['allow_terminal_at_activation']
    return remindable.status.in?(%w[cancelled completed no_show]) if remindable.is_a?(Scheduling::Appointment)
    return remindable.closed? || remindable.archived_at.present? if remindable.is_a?(Crm::Deal)

    true
  end

  private

  def materialized_steps
    definition_resolver.definitions.each_with_index.filter_map do |definition, index|
      due_at = materialized_due_at(definition)
      next if due_at.blank?

      step_key = stable_step_key(definition)
      Step.new(
        definition: definition,
        due_at: due_at,
        index: index,
        step_key: step_key,
        occurrence_key: "#{enrollment.id}:#{step_key}"
      )
    end
  end

  def materialized_due_at(definition)
    params = definition.with_indifferent_access
    probe = Reminder.new(
      account: enrollment.account,
      remindable: enrollment.remindable,
      timing_mode: params[:timing_mode],
      relative_anchor: params[:relative_anchor],
      relative_offset_seconds: params[:relative_offset_seconds],
      relative_time_mode: params[:relative_time_mode],
      relative_time_of_day: params[:relative_time_of_day],
      timezone: params[:timezone].presence || 'UTC'
    )
    probe.created_at = enrollment.activated_at
    probe.send(:materialize_schedule)
    probe.scheduled_at
  end

  def stable_step_key(definition)
    params = definition.with_indifferent_access
    return params[:step_id].to_s if params[:step_id].present?
    return enrollment.source_action_id.to_s if enrollment.source_action_id.present?

    raise ArgumentError, 'Live touch definition is missing a stable step id'
  end

  def definition_resolver
    @definition_resolver ||= Reminders::EnrollmentDefinitionResolver.new(enrollment: enrollment)
  end
end
