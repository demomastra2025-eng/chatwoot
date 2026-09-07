class Captain::Tools::Operations::TaskOperations < Captain::Tools::Operations::BaseOperation
  TASK_ID_UNSET = Object.new.freeze
  UPDATE_FIELDS = %i[
    title description activity_type outcome outcome_note priority all_day start_at due_at due_on schedule_timezone custom_attributes
  ].freeze

  def add_current_task_comment(body:)
    raise ArgumentError, 'A task comment is required' if body.blank?
    raise ArgumentError, 'Current task is not available' if current_task.blank?
    raise ArgumentError, 'A user actor is required to create task comments' unless actor.is_a?(User)

    current_task.comments.create!(account: account, user: actor, body: body.to_s.strip)
  end

  def change_current_task_status(status_id: nil, status_name: nil, status_code: nil)
    ensure_feature_enabled!('crm_tasks', 'CRM tasks are not enabled for this account')
    raise ArgumentError, 'Current task is not available' if current_task.blank?

    status = resolve_status(status_id: status_id, status_name: status_name, status_code: status_code)

    ::Crm::Tasks::StatusTransitionService.new(
      account: account,
      task: current_task,
      params: {
        status_id: status.id,
        lock_version: current_task.lock_version
      },
      actor: actor
    ).perform
  end

  def create_task(
    title:,
    description: nil,
    activity_type: nil,
    outcome: nil,
    outcome_note: nil,
    priority: nil,
    all_day: nil,
    start_at: nil,
    due_at: nil,
    due_on: nil,
    schedule_timezone: nil,
    deal_id: nil,
    originating_conversation_id: nil,
    status_id: nil,
    assignee_id: nil,
    team_id: nil,
    custom_attributes: nil
  )
    ensure_feature_enabled!('crm_tasks', 'CRM tasks are not enabled for this account')
    bootstrap_crm_defaults!
    deal_id = optional_positive_id(deal_id)
    originating_conversation_id = optional_positive_id(originating_conversation_id)
    status_id = optional_positive_id(status_id)
    assignee_id = optional_positive_id(assignee_id)
    team_id = optional_positive_id(team_id)

    create_params = {
      title: title,
      description: description,
      activity_type: activity_type,
      outcome: outcome,
      outcome_note: outcome_note,
      priority: priority,
      all_day: all_day,
      start_at: start_at,
      due_at: due_at,
      due_on: due_on,
      schedule_timezone: schedule_timezone,
      deal_id: deal_id.presence || current_deal&.id,
      originating_conversation_id: resolved_originating_conversation_id(originating_conversation_id) || conversation&.id,
      status_id: status_id,
      assignee_id: assignee_id,
      team_id: team_id,
      custom_attributes: parsed_hash(custom_attributes, field_name: 'custom_attributes')
    }.compact

    with_idempotent_creation('create_task', create_params) do
      ::Crm::Tasks::UpsertService.new(
        account: account,
        params: create_params,
        actor: actor
      ).perform
    end
  end

  def update_current_task(task_id: TASK_ID_UNSET, **attributes)
    ensure_feature_enabled!('crm_tasks', 'CRM tasks are not enabled for this account')
    attributes.assert_valid_keys(*UPDATE_FIELDS)
    task = task_for_update(task_id)
    raise ArgumentError, 'Current task is not available' if task.blank?

    ::Crm::Tasks::UpsertService.new(
      account: account,
      params: task_update_params(task, attributes),
      task: task,
      actor: actor
    ).perform
  end

  def complete_task(task_id:)
    ensure_feature_enabled!('crm_tasks', 'CRM tasks are not enabled for this account')
    task_id = required_positive_id(task_id, field_name: 'task_id')

    task = account.crm_tasks.kept.find_by(id: task_id)
    raise ArgumentError, 'Task not found' if task.blank?

    ::Crm::Tasks::StatusTransitionService.new(
      account: account,
      task: task,
      params: {
        status_id: resolve_done_status.id,
        lock_version: task.lock_version
      },
      actor: actor
    ).perform
  end

  private

  def task_update_params(task, attributes)
    params = { lock_version: task.lock_version }
    params.merge!(attributes.except(:title, :custom_attributes).compact)
    params[:title] = attributes[:title] if attributes[:title].present?
    if attributes[:custom_attributes].present?
      params[:custom_attributes] = parsed_hash(attributes[:custom_attributes], field_name: 'custom_attributes')
    end
    params
  end

  def task_for_update(task_id)
    return current_task if task_id.equal?(TASK_ID_UNSET)

    normalized_task_id = optional_positive_id(task_id)
    raise ArgumentError, 'task_id must be a positive integer' if normalized_task_id.blank?

    account.crm_tasks.find(normalized_task_id)
  end

  def resolve_status(status_id:, status_name:, status_code:)
    status_id = optional_positive_id(status_id)

    return account.crm_task_statuses.find_by!(name: status_name.to_s.strip) if status_name.present?
    return account.crm_task_statuses.find_by!(code: status_code.to_s.strip) if status_code.present?
    return account.crm_task_statuses.find(status_id) if status_id.present?

    raise ArgumentError, 'One of status_id, status_name, or status_code is required'
  end

  def resolved_originating_conversation_id(conversation_id)
    return if conversation_id.blank?

    conversation = account.conversations.find_by(display_id: conversation_id) || account.conversations.find_by(id: conversation_id)
    raise ArgumentError, 'Conversation not found' if conversation.blank?

    conversation.id
  end

  def resolve_done_status
    account.crm_task_statuses.active.find_by(code: 'done') ||
      account.crm_task_statuses.active.where(category: 'done').ordered.first ||
      raise(ArgumentError, 'Done task status not found')
  end
end
