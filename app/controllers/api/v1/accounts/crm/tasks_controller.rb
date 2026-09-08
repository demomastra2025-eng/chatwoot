class Api::V1::Accounts::Crm::TasksController < Api::V1::Accounts::Crm::BaseController
  CREATE_PARAM_KEYS = %i[
    deal_id
    status_id
    assignee_id
    creator_id
    team_id
    originating_conversation_id
    title
    description
    task_type_id
    task_outcome_id
    activity_type
    outcome
    outcome_note
    priority
    all_day
    due_on
    schedule_timezone
    start_at
    due_at
    position
    external_ref
    idempotency_key
  ].freeze
  UPDATE_PARAM_KEYS = %i[
    deal_id
    assignee_id
    creator_id
    team_id
    originating_conversation_id
    title
    description
    task_type_id
    task_outcome_id
    activity_type
    outcome
    outcome_note
    priority
    all_day
    due_on
    schedule_timezone
    start_at
    due_at
    position
    external_ref
    idempotency_key
    lock_version
  ].freeze

  before_action :ensure_crm_tasks_enabled!
  before_action :bootstrap_defaults!, only: [:index, :create, :complete, :cancel, :reopen]
  before_action :set_task,
                only: [:show, :update, :timeline, :change_status, :complete, :cancel, :reopen, :reschedule, :assign,
                       :archive, :unarchive]

  def index
    authorize ::Crm::Task

    tasks = filtered_tasks
    render_payload(
      tasks.map { |task| ::Crm::PayloadBuilder.task(task) },
      meta: { count: tasks.size }
    )
  end

  def show
    authorize @task
    render_payload(::Crm::PayloadBuilder.task(@task))
  end

  def create
    authorize ::Crm::Task

    existing_task = idempotent_task
    return render_payload(::Crm::PayloadBuilder.task(existing_task)) if existing_task.present?

    task = ::Crm::Tasks::UpsertService.new(
      account: Current.account,
      params: create_task_params,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.task(task), status: :created)
  end

  def update
    authorize @task

    task = ::Crm::Tasks::UpsertService.new(
      account: Current.account,
      params: update_task_params,
      task: @task,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.task(task))
  end

  def timeline
    authorize @task

    timeline = ::Crm::Timelines::TaskService.new(
      account: Current.account,
      task: @task,
      actor: Current.user,
      params: params.permit(:before, :limit)
    ).perform

    render_payload(timeline[:items], meta: timeline[:meta])
  end

  def change_status
    authorize @task, :change_status?

    task = ::Crm::Tasks::StatusTransitionService.new(
      account: Current.account,
      task: @task,
      params: params.permit(:status_id, :position, :lock_version, :idempotency_key, :task_outcome_id, :outcome, :outcome_note, :cancellation_reason),
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.task(task))
  end

  def complete
    run_task_command!(
      ::Crm::Tasks::CompleteService,
      params.permit(:task_outcome_id, :outcome, :outcome_note, :lock_version, :idempotency_key)
    )
  end

  def cancel
    run_task_command!(
      ::Crm::Tasks::CancelService,
      params.permit(:cancellation_reason, :lock_version, :idempotency_key)
    )
  end

  def reopen
    run_task_command!(::Crm::Tasks::ReopenService, params.permit(:lock_version, :idempotency_key))
  end

  def reschedule
    run_task_command!(
      ::Crm::Tasks::RescheduleService,
      params.permit(:all_day, :due_on, :due_at, :start_at, :schedule_timezone, :lock_version, :idempotency_key)
    )
  end

  def assign
    run_task_command!(::Crm::Tasks::AssignService, params.permit(:assignee_id, :lock_version, :idempotency_key))
  end

  def archive
    authorize @task, :archive?

    task = ::Crm::Tasks::ArchiveService.new(
      account: Current.account,
      task: @task,
      params: params.permit(:lock_version),
      archived: true,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.task(task))
  end

  def unarchive
    authorize @task, :unarchive?

    task = ::Crm::Tasks::ArchiveService.new(
      account: Current.account,
      task: @task,
      params: params.permit(:lock_version),
      archived: false,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.task(task))
  end

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def create_task_params
    params.permit(*CREATE_PARAM_KEYS, custom_attributes: {})
  end

  def filter_by_due_range(scope)
    from = parse_datetime_param!(params[:due_from], field_name: 'due_from', required: false)
    to = parse_datetime_param!(params[:due_to], field_name: 'due_to', required: false)
    return scope if from.blank? && to.blank?

    timezone = Current.account.workspace_working_hours_timezone
    from_date = from&.in_time_zone(timezone)&.to_date
    to_date = to&.in_time_zone(timezone)&.to_date
    scope.where(due_range_clause(from: from, to: to), from: from, to: to, from_date: from_date, to_date: to_date)
  end

  def due_range_clause(from:, to:)
    return <<~SQL.squish if from.present? && to.present?
      (crm_tasks.due_at >= :from AND crm_tasks.due_at < :to) OR
      (crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date)
    SQL
    return 'crm_tasks.due_at >= :from OR crm_tasks.due_on >= :from_date' if from.present?

    'crm_tasks.due_at < :to OR crm_tasks.due_on < :to_date'
  end

  def filter_by_exact(scope, field_name)
    return scope if params[field_name].blank?

    scope.where(field_name => params[field_name])
  end

  def filter_by_query(scope)
    return scope if params[:q].blank?

    query = "%#{params[:q].to_s.strip}%"
    scope.where('crm_tasks.title ILIKE :query OR crm_tasks.external_ref ILIKE :query', query: query)
  end

  def filtered_tasks
    scope = policy_scope(::Crm::Task).includes(:task_type, :task_outcome).ordered
    scope = parse_boolean(params[:archived]) ? scope.archived : scope.kept
    scope = filter_by_exact(scope, :status_id)
    scope = filter_by_exact(scope, :activity_type)
    scope = filter_by_exact(scope, :task_type_id)
    scope = filter_by_exact(scope, :task_outcome_id)
    scope = filter_by_exact(scope, :outcome)
    scope = filter_by_exact(scope, :assignee_id)
    scope = filter_by_exact(scope, :team_id)
    scope = filter_by_exact(scope, :priority)
    scope = filter_by_exact(scope, :deal_id)
    scope = filter_by_due_range(scope)
    scope = filter_by_query(scope)

    ::Crm::CustomFieldFilterSet.new(
      account: Current.account,
      entity_kind: 'task',
      raw_filters: custom_attribute_filters_param
    ).apply(scope)
  end

  def idempotent_task
    return if create_task_params[:idempotency_key].blank?

    Current.account.crm_tasks.find_by(idempotency_key: create_task_params[:idempotency_key])
  end

  def set_task
    @task = policy_scope(::Crm::Task).find(params[:id])
  end

  def update_task_params
    params.permit(*UPDATE_PARAM_KEYS, custom_attributes: {})
  end

  def run_task_command!(service_class, command_params)
    authorize @task, :"#{action_name}?"
    task = service_class.new(
      account: Current.account,
      task: @task,
      params: command_params,
      actor: Current.user
    ).perform
    render_payload(::Crm::PayloadBuilder.task(task))
  end
end
