class Crm::Tasks::UpsertService < Crm::BaseWriteService
  def initialize(account:, params:, task: nil, actor: nil, broadcast_linked_deal: true)
    @task = task || account.crm_tasks.new
    @broadcast_linked_deal = broadcast_linked_deal
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    new_record = task.new_record?
    saved_task = ApplicationRecord.transaction do
      bootstrap_defaults!
      assert_lock_version!

      requested_position = resolve_requested_position
      deal = resolve_optional_record(:deal_id, account.crm_deals, current: task.deal)
      status = resolve_status!
      task_type = resolve_task_type!
      task_outcome = resolve_task_outcome(task_type)
      originating_conversation = resolve_originating_conversation(deal: deal)
      assignee = resolve_assignee(deal: deal, originating_conversation: originating_conversation)
      creator = resolve_optional_record(:creator_id, account.users, current: task.creator || actor)
      team = resolve_team(deal: deal)
      external_ref = resolve_optional_text(:external_ref, current: task.external_ref)
      idempotency_key = resolve_optional_text(:idempotency_key, current: task.idempotency_key)

      ensure_unique_reference!(scope: account.crm_tasks, attribute: :external_ref, value: external_ref, code: 'DUPLICATE_EXTERNAL_REF')
      ensure_unique_reference!(scope: account.crm_tasks, attribute: :idempotency_key, value: idempotency_key, code: 'DUPLICATE_IDEMPOTENCY_KEY')

      custom_attributes = field_catalog(deal: deal).resolve_custom_attributes(
        current_attributes: task.custom_attributes,
        incoming_attributes: params[:custom_attributes],
        apply_defaults: new_record
      )

      task.assign_attributes(
        account: account,
        deal: deal,
        status: status,
        task_type: task_type,
        task_outcome: task_outcome,
        assignee: assignee,
        creator: creator,
        team: team,
        originating_conversation: originating_conversation,
        title: resolve_title,
        description: resolve_optional_text(:description, current: task.description),
        activity_type: task_type.code,
        outcome: task_outcome&.code,
        outcome_note: resolve_optional_text(:outcome_note, current: task.outcome_note),
        priority: resolve_optional_text(:priority, current: task.priority || 'medium'),
        all_day: resolve_all_day,
        due_on: resolve_due_on,
        schedule_timezone: resolve_schedule_timezone,
        start_at: resolve_datetime(:start_at, current: task.start_at),
        due_at: resolve_datetime(:due_at, current: task.due_at),
        completed_at: resolve_completed_at(status: status),
        external_ref: external_ref,
        idempotency_key: idempotency_key,
        custom_attributes: custom_attributes
      )
      task.position = requested_position if requested_position.present?
      task.save!
      auto_apply_default_touch_plan! if new_record
      sync_related_touches!
      reposition_task!(requested_position) if requested_position.present?

      write_event!(new_record: new_record)
      notify_assignment!(new_record: new_record)

      task.reload
    end
    dispatch_crm_task_realtime_event!(
      new_record ? Events::Types::CRM_TASK_CREATED : Events::Types::CRM_TASK_UPDATED,
      saved_task,
      meta: { event_type: new_record ? 'task_created' : 'task_updated' }
    )
    dispatch_linked_deal_update!(saved_task, event_type: 'task_changed') if broadcast_linked_deal
    saved_task
  end

  private

  attr_reader :task, :broadcast_linked_deal

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform if account.feature_enabled?('crm_tasks')
  end

  def field_catalog(deal:)
    context = deal.present? ? 'deal_task' : 'standalone_task'
    ::Crm::FieldCatalog.new(account: account, entity_kind: 'task', context: context)
  end

  def resolve_assignee(deal:, originating_conversation:)
    return resolve_optional_record(:assignee_id, account.users, current: task.assignee) if params.key?(:assignee_id)
    return task.assignee if task.persisted?

    deal&.owner || originating_conversation&.contact&.owner || originating_conversation&.assignee
  end

  def resolve_originating_conversation(deal:)
    if params.key?(:originating_conversation_id)
      return resolve_optional_record(
        :originating_conversation_id,
        account.conversations,
        current: task.originating_conversation
      )
    end

    return task.originating_conversation if task.persisted?

    deal&.originating_conversation
  end

  def resolve_completed_at(status:)
    return task.completed_at unless task.new_record? || params.key?(:status_id)

    status.category_done? ? Time.zone.now : nil
  end

  def resolve_status!
    return account.crm_task_statuses.find(params[:status_id]) if params.key?(:status_id) && params[:status_id].present?
    return task.status if task.persisted?

    account.crm_task_statuses.active.find_by(default: true) ||
      account.crm_task_statuses.active.where(category: 'open').ordered.first ||
      account.crm_task_statuses.active.ordered.first ||
      validation_error!('status_id', 'must reference an active status')
  end

  def resolve_task_type!
    if params.key?(:task_type_id) && params[:task_type_id].present?
      return account.crm_task_types.find(params[:task_type_id])
    end
    if params.key?(:activity_type)
      code = params[:activity_type].to_s.strip.downcase
      return account.crm_task_types.find_by(code: code) || validation_error!('activity_type', 'is not configured')
    end
    return task.task_type if task.persisted?

    account.crm_task_types.active.find_by(default: true) ||
      account.crm_task_types.active.ordered.first ||
      validation_error!('task_type_id', 'must reference an active task type')
  end

  def resolve_task_outcome(task_type)
    return resolve_outcome_by_id(task_type) if params.key?(:task_outcome_id)
    return resolve_outcome_by_code(task_type) if params.key?(:outcome)
    return nil if task.task_type_id.present? && task.task_type_id != task_type.id

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
    if deal.present?
      requested_team = resolve_optional_record(:team_id, account.teams, current: deal.team)
      validation_error!('team_id', 'is inherited from deal') if requested_team != deal.team

      return deal.team
    end

    return resolve_optional_record(:team_id, account.teams, current: task.team) if params.key?(:team_id)
    return nil if params.key?(:deal_id)
    return task.team if task.persisted?

    nil
  end

  def resolve_title
    title = resolve_optional_text(:title, current: task.title)
    validation_error!('title', 'is required') if title.blank?

    title
  end

  def resolve_all_day
    return task.all_day unless params.key?(:all_day)

    ActiveModel::Type::Boolean.new.cast(params[:all_day])
  end

  def resolve_due_on
    return resolve_date(:due_on, current: task.due_on) if params.key?(:due_on)
    return if resolve_all_day && params.key?(:due_at)

    task.due_on
  end

  def resolve_schedule_timezone
    resolve_optional_text(
      :schedule_timezone,
      current: task.schedule_timezone || account.workspace_working_hours_timezone
    )
  end

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: task.position, allow_nil: true)
  end

  def reposition_task!(requested_position)
    ::Crm::BoardPositioner.place!(
      scope: account.crm_tasks.kept.where(status_id: task.status_id),
      record: task,
      target_position: requested_position
    )
  end

  def write_event!(new_record:)
    return unless new_record || filtered_previous_changes.present?

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: task,
      actor: actor,
      event_type: new_record ? 'task_created' : 'task_updated',
      meta: { changes: filtered_previous_changes },
      command_key: new_record ? params[:idempotency_key] : nil
    )
  end

  def notify_assignment!(new_record:)
    return unless new_record || task.previous_changes.key?('assignee_id')

    ::Crm::AssignmentNotificationService.new(
      account: account,
      record: task,
      user: task.assignee,
      notification_type: 'task_assignment',
      actor: actor
    ).perform
  end

  def auto_apply_default_touch_plan!
    Reminders::DefaultPlanService.new(
      account: account,
      remindable: task,
      actor: actor
    ).perform
  end

  def sync_related_touches!
    Reminders::SyncRemindableService.new(remindable: task).perform
  end
end
