class Crm::Tasks::CompleteService < Crm::Tasks::CommandService
  private

  def event_type
    'task_completed'
  end

  def no_op?
    task.completed? && !params.key?(:task_outcome_id) && !params.key?(:outcome) && !params.key?(:outcome_note)
  end

  def apply_command!
    @was_completed = task.completed?
    ensure_required_fields!
    outcome = resolve_outcome!
    note = resolve_optional_text(:outcome_note, current: task.outcome_note)
    validation_error!('outcome_note', 'is required for the selected result') if outcome.requires_note? && note.blank?

    apply_completion(outcome, note)
    transition_status!(active_status_for!('done'))
  end

  def apply_completion(outcome, note)
    task.task_outcome = outcome
    task.outcome = outcome.code
    task.outcome_note = note
    task.completed_at ||= Time.zone.now
    task.completed_by = actor unless @was_completed
    task.cancelled_at = nil
    task.cancelled_by = nil
    task.cancellation_reason = nil
  end

  def command_event_type(before_data)
    return event_type unless @was_completed

    before_data['status_id'] == task.status_id ? 'task_updated' : 'task_status_changed'
  end

  def ensure_required_fields!
    inspector = Crm::RequiredFieldsInspector.new(
      account: account,
      entity_kind: 'task',
      custom_attributes: task.custom_attributes,
      context: task.custom_field_context
    )
    return if inspector.complete?

    raise Crm::Error.new(
      code: 'TASK_STATUS_REQUIRES_FIELDS',
      message: "Complete required fields before marking the task as done: #{inspector.missing_field_labels.join(', ')}",
      status: :unprocessable_content,
      details: { missing_fields: inspector.missing_field_details }
    )
  end
end
