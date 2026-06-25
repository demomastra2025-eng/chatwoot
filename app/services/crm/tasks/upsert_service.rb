class Crm::Tasks::UpsertService < Crm::BaseWriteService
  def initialize(account:, params:, task: nil, actor: nil)
    @task = task || account.crm_tasks.new
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      bootstrap_defaults!
      assert_lock_version!

      new_record = task.new_record?
      requested_position = resolve_requested_position
      deal = resolve_optional_record(:deal_id, account.crm_deals, current: task.deal)
      status = resolve_status!
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
        assignee: assignee,
        creator: creator,
        team: team,
        originating_conversation: originating_conversation,
        title: resolve_title,
        description: resolve_optional_text(:description, current: task.description),
        priority: resolve_optional_text(:priority, current: task.priority || 'medium'),
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
  end

  private

  attr_reader :task

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

  def resolve_team(deal:)
    return resolve_optional_record(:team_id, account.teams, current: task.team) if params.key?(:team_id)
    return task.team if task.persisted?

    deal&.team
  end

  def resolve_title
    title = resolve_optional_text(:title, current: task.title)
    validation_error!('title', 'is required') if title.blank?

    title
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
      meta: { changes: filtered_previous_changes }
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
