class Captain::Tools::Operations::TaskOperations < Captain::Tools::Operations::BaseOperation
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
    start_at: nil,
    due_at: nil,
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
      start_at: start_at,
      due_at: due_at,
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

  def update_current_task(
    title: nil,
    description: nil,
    activity_type: nil,
    outcome: nil,
    outcome_note: nil,
    priority: nil,
    start_at: nil,
    due_at: nil,
    custom_attributes: nil
  )
    ensure_feature_enabled!('crm_tasks', 'CRM tasks are not enabled for this account')
    raise ArgumentError, 'Current task is not available' if current_task.blank?

    params = {
      lock_version: current_task.lock_version
    }
    params[:title] = title if title.present?
    params[:description] = description unless description.nil?
    params[:activity_type] = activity_type unless activity_type.nil?
    params[:outcome] = outcome unless outcome.nil?
    params[:outcome_note] = outcome_note unless outcome_note.nil?
    params[:priority] = priority unless priority.nil?
    params[:start_at] = start_at unless start_at.nil?
    params[:due_at] = due_at unless due_at.nil?

    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    ::Crm::Tasks::UpsertService.new(
      account: account,
      params: params,
      task: current_task,
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

  def resolve_status(status_id:, status_name:, status_code:)
    status_id = optional_positive_id(status_id)

    return account.crm_task_statuses.find(status_id) if status_id.present?
    return account.crm_task_statuses.find_by!(code: status_code.to_s.strip) if status_code.present?
    return account.crm_task_statuses.find_by!(name: status_name.to_s.strip) if status_name.present?

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
