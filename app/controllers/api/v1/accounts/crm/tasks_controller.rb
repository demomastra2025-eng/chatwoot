class Api::V1::Accounts::Crm::TasksController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :bootstrap_defaults!, only: [:create, :complete, :cancel, :reopen]
  before_action :set_task,
                only: [:show, :update, :save_form, :timeline, :change_status, :complete, :cancel, :reopen, :reschedule, :assign,
                       :archive, :unarchive]

  def index
    authorize ::Crm::Task
    normalize_time_bucket_as_of!

    scope = filtered_tasks
    total_count = scope.count
    list_page = ::Crm::Tasks::ListOrderService.new(scope: scope, params: params)
    tasks = list_page.perform
    catalog_snapshot = ::Crm::Tasks::CatalogSnapshot.new(account: Current.account)
    render_payload(
      tasks.map { |task| ::Crm::PayloadBuilder.task(task, catalog_snapshot: catalog_snapshot) },
      meta: {
        count: total_count,
        page: list_page.page,
        per_page: list_page.per_page,
        has_more: (list_page.page * list_page.per_page) < total_count,
        as_of: params[:time_bucket].present? ? params[:as_of] : nil
      }.compact
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
    reject_command_only_update_params!

    task = ::Crm::Tasks::SaveFormService.new(
      account: Current.account,
      params: update_task_params.to_h.merge(idempotency_key: request.request_id),
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

  def save_form
    run_task_command!(
      ::Crm::Tasks::SaveFormService,
      params.permit(*::Crm::Tasks::RequestParams::FORM_KEYS, :status_id, :cancellation_reason, custom_attributes: {})
    )
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

  def normalize_time_bucket_as_of!
    return if params[:time_bucket].blank?

    timezone = Current.account.workspace_working_hours_timezone
    parsed_as_of = Time.zone.parse(params[:as_of].to_s) if params[:as_of].present?
    params[:as_of] = (parsed_as_of || Time.current).in_time_zone(timezone).iso8601(6)
  rescue ArgumentError, TypeError
    params[:as_of] = Time.current.in_time_zone(timezone).iso8601(6)
  end

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def create_task_params
    params.permit(*::Crm::Tasks::RequestParams::CREATE_KEYS, custom_attributes: {})
  end

  def filtered_tasks
    ::Crm::Tasks::FilterService.new(
      account: Current.account,
      scope: policy_scope(::Crm::Task).includes(:task_type, :task_outcome).ordered,
      params: params,
      custom_attribute_filters: custom_attribute_filters_param
    ).perform
  end

  def idempotent_task
    return if create_task_params[:idempotency_key].blank?

    existing_task = Current.account.crm_tasks.find_by(idempotency_key: create_task_params[:idempotency_key])
    return if existing_task.blank?

    policy_scope(Current.account.crm_tasks).find(existing_task.id)
  end

  def set_task
    @task = policy_scope(::Crm::Task).find(params[:id])
  end

  def update_task_params
    params.permit(*::Crm::Tasks::RequestParams::UPDATE_KEYS, custom_attributes: {})
  end

  def reject_command_only_update_params!
    fields = ::Crm::Tasks::RequestParams::COMMAND_ONLY_UPDATE_KEYS.select { |key| params.key?(key) }
    return if fields.empty?

    raise Crm::Error.new(
      code: 'TASK_COMMAND_REQUIRED',
      message: 'Task lifecycle fields must be changed through a task command',
      status: :unprocessable_content,
      details: { fields: fields }
    )
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
