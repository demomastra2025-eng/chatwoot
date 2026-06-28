class Crm::Tasks::StatusTransitionService < Crm::BaseWriteService
  def initialize(account:, task:, params:, actor: nil)
    @task = task
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    target_status = account.crm_task_statuses.find(params[:status_id])
    requested_position = resolve_requested_position
    return task if task.status_id == target_status.id && requested_position.blank? && !outcome_attributes_requested?

    ApplicationRecord.transaction do
      task.lock!
      assert_lock_version!

      ensure_required_fields_for_done_status!(target_status)
      transition_to_status!(target_status)
    end
  end

  private

  attr_reader :task

  def transition_to_status!(target_status)
    from_status_id = task.status_id
    requested_position = resolve_requested_position
    status_changed = from_status_id != target_status.id

    task.status = target_status
    task.position = requested_position if requested_position.present?
    task.completed_at = target_status.category_done? ? Time.zone.now : nil
    task.outcome = resolve_optional_text(:outcome, current: task.outcome)
    task.outcome_note = resolve_optional_text(:outcome_note, current: task.outcome_note)
    task.save!

    if status_changed || requested_position.present?
      ::Crm::BoardPositioner.place!(
        scope: account.crm_tasks.kept.where(status_id: target_status.id),
        record: task,
        target_position: requested_position
      )
    end

    if status_changed
      ::Crm::BoardPositioner.normalize!(
        scope: account.crm_tasks.kept.where(status_id: from_status_id)
      )

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: task,
        actor: actor,
        event_type: 'task_status_changed',
        meta: {
          from_status_id: from_status_id,
          to_status_id: target_status.id
        }
      )
    end

    task.reload
  end

  def ensure_required_fields_for_done_status!(target_status)
    return unless target_status.category_done?

    inspector = Crm::RequiredFieldsInspector.new(
      account: account,
      entity_kind: 'task',
      custom_attributes: task.custom_attributes,
      context: task.deal_id.present? ? 'deal_task' : 'standalone_task'
    )
    return if inspector.complete?

    raise ::Crm::Error.new(
      code: 'TASK_STATUS_REQUIRES_FIELDS',
      message: "Complete required fields before marking the task as done: #{inspector.missing_field_labels.join(', ')}",
      status: :unprocessable_content,
      details: {
        missing_fields: inspector.missing_field_details
      }
    )
  end

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: task.position, allow_nil: true)
  end

  def outcome_attributes_requested?
    params.key?(:outcome) || params.key?(:outcome_note)
  end
end
