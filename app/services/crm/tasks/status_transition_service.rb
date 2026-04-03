class Crm::Tasks::StatusTransitionService < Crm::BaseWriteService
  def initialize(account:, task:, params:, actor: nil)
    @task = task
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    target_status = account.crm_task_statuses.find(params[:status_id])
    return task if task.status_id == target_status.id

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

    task.status = target_status
    task.completed_at = target_status.category_done? ? Time.zone.now : nil
    task.save!

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
end
