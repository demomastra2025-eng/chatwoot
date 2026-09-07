module Crm::Tasks::UpsertRelations
  private

  def resolve_assignee(deal:, originating_conversation:)
    return requested_assignee if params.key?(:assignee_id)
    return task.assignee if task.persisted?

    default_assignee(deal, originating_conversation)
  end

  def requested_assignee
    resolve_optional_record(:assignee_id, account.users, current: task.assignee)
  end

  def default_assignee(deal, conversation)
    deal_owner(deal) || conversation_contact_owner(conversation) || conversation&.assignee
  end

  def deal_owner(deal)
    deal&.owner
  end

  def conversation_contact_owner(conversation)
    conversation&.contact&.owner
  end

  def resolve_originating_conversation(deal:)
    return requested_originating_conversation if params.key?(:originating_conversation_id)
    return task.originating_conversation if task.persisted?

    deal&.originating_conversation
  end

  def requested_originating_conversation
    resolve_optional_record(
      :originating_conversation_id,
      account.conversations,
      current: task.originating_conversation
    )
  end

  def resolve_completed_at(status:)
    return task.completed_at unless task.new_record? || params.key?(:status_id)

    status.category_done? ? Time.zone.now : nil
  end

  def resolve_status!
    return account.crm_task_statuses.find(params[:status_id]) if requested_status_id?
    return task.status if task.persisted?

    default_status || validation_error!('status_id', 'must reference an active status')
  end

  def requested_status_id?
    params.key?(:status_id) && params[:status_id].present?
  end

  def default_status
    statuses = account.crm_task_statuses.active
    statuses.find_by(default: true) || statuses.where(category: 'open').ordered.first || statuses.ordered.first
  end

  def resolve_task_type!
    return account.crm_task_types.find(params[:task_type_id]) if requested_task_type_id?
    return task_type_by_activity if params.key?(:activity_type)
    return task.task_type if task.persisted?

    default_task_type || validation_error!('task_type_id', 'must reference an active task type')
  end

  def requested_task_type_id?
    params.key?(:task_type_id) && params[:task_type_id].present?
  end

  def task_type_by_activity
    code = params[:activity_type].to_s.strip.downcase
    account.crm_task_types.find_by(code: code) || validation_error!('activity_type', 'is not configured')
  end

  def default_task_type
    types = account.crm_task_types.active
    types.find_by(default: true) || types.ordered.first
  end

  def resolve_task_outcome(task_type)
    return resolve_outcome_by_id(task_type) if params.key?(:task_outcome_id)
    return resolve_outcome_by_code(task_type) if params.key?(:outcome)
    return if task.task_type_id.present? && task.task_type_id != task_type.id

    task.task_outcome
  end

  def resolve_outcome_by_id(task_type)
    return if params[:task_outcome_id].blank?

    outcome = account.crm_task_outcomes.find(params[:task_outcome_id])
    validation_error!('task_outcome_id', 'does not belong to the selected task type') if outcome.task_type_id != task_type.id
    outcome
  end

  def resolve_outcome_by_code(task_type)
    code = params[:outcome].to_s.strip.downcase
    return if code.blank?

    task_type.outcomes.find_by(code: code) || validation_error!('outcome', 'is not configured for the selected task type')
  end

  def resolve_team(deal:)
    return inherited_deal_team(deal) if deal.present?
    return resolve_optional_record(:team_id, account.teams, current: task.team) if params.key?(:team_id)
    return if params.key?(:deal_id)

    task.team if task.persisted?
  end

  def inherited_deal_team(deal)
    requested_team = resolve_optional_record(:team_id, account.teams, current: deal.team)
    validation_error!('team_id', 'is inherited from deal') if requested_team != deal.team
    deal.team
  end
end
