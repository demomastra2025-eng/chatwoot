require 'digest'

class Reminders::EnrollmentScheduleService
  Step = Struct.new(:definition, :due_at, :index, :occurrence_key, :step_key, keyword_init: true)

  attr_reader :enrollment

  def initialize(enrollment:)
    @enrollment = enrollment
  end

  def pending_steps
    claimed_keys = enrollment.touch_occurrence_claims.pluck(:occurrence_key).to_set
    materialized_steps.reject { |step| claimed_keys.include?(step.occurrence_key) }.sort_by { |step| [step.due_at, step.index] }
  end

  def next_step
    pending_steps.first
  end

  def refresh_next_due!
    step = next_step
    enrollment.update!(status: step ? 'active' : 'completed', next_due_at: step&.due_at)
    step
  end

  def terminal_remindable?
    remindable = enrollment.remindable
    return true if remindable.blank?
    return remindable.status.in?(%w[cancelled completed]) if remindable.is_a?(Scheduling::Appointment)
    return remindable.closed? || remindable.archived_at.present? if remindable.is_a?(Crm::Deal)

    true
  end

  private

  def materialized_steps
    enrollment.plan_snapshot.each_with_index.filter_map do |definition, index|
      due_at = materialized_due_at(definition)
      next if due_at.blank?

      step_key = Digest::SHA256.hexdigest([index, definition.to_json].join(':'))
      Step.new(
        definition: definition,
        due_at: due_at,
        index: index,
        step_key: step_key,
        occurrence_key: Digest::SHA256.hexdigest([enrollment.id, step_key].join(':'))
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
    probe.send(:materialize_schedule)
    probe.scheduled_at
  end
end
