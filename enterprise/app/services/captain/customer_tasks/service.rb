class Captain::CustomerTasks::Service
  MUTATING_ACTIONS = %w[create update cancel].freeze
  TERMINAL_STATUS_CATEGORIES = %w[done cancelled].freeze
  MAX_LIST_SIZE = 100
  IDEMPOTENCY_RECOVERY_ATTEMPTS = 3
  IDEMPOTENCY_RECOVERY_BACKOFF = 0.01
  IDEMPOTENCY_UNIQUE_INDEX = 'index_crm_tasks_on_account_idempotency_key'.freeze

  def initialize(assistant:, conversation:)
    @assistant = assistant
    @account = assistant.account
    @conversation = conversation
  end

  def call(action:, task_id: nil, title: nil, task_type: nil, all_day: nil, due_at: nil, due_on: nil,
           request_reason: nil, idempotency_key: nil)
    validate_context!
    action = action.to_s
    validate_idempotency_key!(action, idempotency_key)

    case action
    when 'list'
      list_tasks
    when 'create'
      create_task(
        title: title,
        task_type: task_type,
        all_day: all_day,
        due_at: due_at,
        due_on: due_on,
        idempotency_key: idempotency_key
      )
    when 'update'
      update_task(
        task_id: task_id,
        title: title,
        all_day: all_day,
        due_at: due_at,
        due_on: due_on,
        request_reason: request_reason,
        idempotency_key: idempotency_key
      )
    when 'cancel'
      cancel_task(task_id: task_id, request_reason: request_reason, idempotency_key: idempotency_key)
    else
      raise ArgumentError, 'action must be list, create, update, or cancel'
    end
  end

  private

  attr_reader :assistant, :account, :conversation

  def list_tasks
    relation = customer_scope.order(updated_at: :desc, id: :desc)
    rows = relation.limit(MAX_LIST_SIZE + 1).to_a
    {
      action: 'list',
      tasks: rows.first(MAX_LIST_SIZE).map { |task| customer_payload(task) },
      meta: { count: [rows.size, MAX_LIST_SIZE].min, has_more: rows.size > MAX_LIST_SIZE }
    }
  end

  def create_task(title:, task_type:, all_day:, due_at:, due_on:, idempotency_key:)
    customer_title = title.to_s.strip
    raise ArgumentError, 'title is required' if customer_title.blank?

    existing_task = customer_scope.find_by(idempotency_key: idempotency_key)
    return { action: 'created', task: customer_payload(existing_task) } if existing_task

    Crm::Bootstrap::AccountService.new(account: account).perform
    resolved_type = resolve_task_type(task_type)
    route = Crm::Tasks::CustomerRoutingResolver.call(
      account: account,
      contact: contact,
      conversation: conversation,
      task_type: resolved_type
    )
    task = Crm::Tasks::UpsertService.new(
      account: account,
      actor: nil,
      params: compact_hash(
        title: customer_title,
        customer_visible: true,
        customer_title: customer_title,
        task_type_id: resolved_type.id,
        context_kind: route.deal ? 'sales' : 'personal',
        deal_id: route.deal&.id,
        originating_conversation_id: conversation.id,
        assignee_id: route.assignee.id,
        team_id: route.team&.id,
        all_day: all_day,
        due_at: due_at,
        due_on: due_on,
        idempotency_key: idempotency_key
      )
    ).perform

    { action: 'created', task: customer_payload(task) }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Crm::Error => e
    raise unless recoverable_idempotency_error?(e, idempotency_key)

    recover_concurrent_create(idempotency_key, e)
  end

  def update_task(task_id:, title:, all_day:, due_at:, due_on:, request_reason:, idempotency_key:)
    task = find_customer_task!(task_id)
    return terminal_result('update_ignored', task) if terminal?(task)

    if task.status.category == 'in_progress'
      reason = request_reason.to_s.strip.presence || title.to_s.strip.presence
      raise ArgumentError, 'request_reason is required for an in-progress task' if reason.blank?

      updated = update_customer_fields(
        task,
        customer_change_request: reason,
        customer_change_requested_at: Time.current,
        idempotency_key: idempotency_key
      )
      return { action: 'change_requested', task: customer_payload(updated) }
    end

    attributes = compact_hash(
      title: title.to_s.strip.presence,
      customer_title: title.to_s.strip.presence,
      all_day: all_day,
      due_at: due_at,
      due_on: due_on,
      customer_change_request: nil,
      customer_change_requested_at: nil,
      lock_version: task.lock_version
    )
    editable_attributes = attributes.except(:customer_change_request, :customer_change_requested_at, :lock_version)
    raise ArgumentError, 'at least one editable customer field is required' if editable_attributes.empty?

    updated = save_customer_form(task, attributes, idempotency_key)
    { action: 'updated', task: customer_payload(updated) }
  end

  def cancel_task(task_id:, request_reason:, idempotency_key:)
    task = find_customer_task!(task_id)
    return terminal_result('cancel_ignored', task) if terminal?(task)

    reason = request_reason.to_s.strip.presence || 'Customer requested cancellation'
    if task.status.category == 'in_progress'
      updated = update_customer_fields(
        task,
        customer_cancellation_request: reason,
        customer_cancellation_requested_at: Time.current,
        idempotency_key: idempotency_key
      )
      return { action: 'cancellation_requested', task: customer_payload(updated) }
    end

    cancelled = Crm::Tasks::CancelService.new(
      account: account,
      task: task,
      actor: nil,
      params: {
        cancellation_reason: reason,
        lock_version: task.lock_version,
        idempotency_key: idempotency_key
      }
    ).perform
    { action: 'cancelled', task: customer_payload(cancelled) }
  end

  def update_customer_fields(task, attributes)
    idempotency_key = attributes.delete(:idempotency_key)
    save_customer_form(task, attributes, idempotency_key)
  end

  def save_customer_form(task, attributes, idempotency_key)
    Crm::Tasks::SaveFormService.new(
      account: account,
      task: task,
      actor: nil,
      params: attributes.merge(lock_version: task.lock_version, idempotency_key: idempotency_key)
    ).perform
  end

  def find_customer_task!(task_id)
    id = task_id.to_i
    raise ArgumentError, 'task_id must be a positive integer' unless id.positive?

    customer_scope.find(id)
  end

  def customer_scope
    Crm::Tasks::CustomerScope.resolve(
      account: account,
      contact: contact,
      communication_thread: communication_thread
    )
  end

  def resolve_task_type(value)
    relation = account.crm_task_types.active
    return relation.find_by!(code: Crm::CodeNormalizer.normalize(value)) if value.present?

    relation.find_by(default: true) || relation.ordered.first || raise(ArgumentError, 'No active task type is configured')
  end

  def customer_payload(task)
    {
      id: task.id,
      title: task.customer_title,
      status: task.status.category,
      deadline: task.effective_due_at&.iso8601,
      result: task.customer_result,
      change_requested: task.customer_change_requested_at.present?,
      cancellation_requested: task.customer_cancellation_requested_at.present?
    }.compact
  end

  def terminal_result(action, task)
    { action: action, task: customer_payload(task) }
  end

  def terminal?(task)
    TERMINAL_STATUS_CATEGORIES.include?(task.status.category)
  end

  def recover_concurrent_create(idempotency_key, error)
    IDEMPOTENCY_RECOVERY_ATTEMPTS.times do |attempt|
      existing_task = ApplicationRecord.uncached { customer_scope.find_by(idempotency_key: idempotency_key) }
      return { action: 'created', task: customer_payload(existing_task) } if existing_task

      sleep(IDEMPOTENCY_RECOVERY_BACKOFF * (attempt + 1)) if attempt < IDEMPOTENCY_RECOVERY_ATTEMPTS - 1
    end

    raise error
  end

  def recoverable_idempotency_error?(error, idempotency_key)
    case error
    when ActiveRecord::RecordNotUnique
      idempotency_constraint_violation?(error)
    when ActiveRecord::RecordInvalid
      duplicate_idempotency_validation?(error, idempotency_key)
    when Crm::Error
      duplicate_idempotency_domain_error?(error)
    else
      false
    end
  end

  def idempotency_constraint_violation?(error)
    cause = error.cause
    result = cause.respond_to?(:result) ? cause.result : nil
    return false if result.blank?

    result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == IDEMPOTENCY_UNIQUE_INDEX
  end

  def duplicate_idempotency_validation?(error, idempotency_key)
    record = error.record
    return false unless record.is_a?(Crm::Task)
    return false unless record.account_id == account.id && record.idempotency_key == idempotency_key

    details = record.errors.details
    details.keys == [:idempotency_key] &&
      details.fetch(:idempotency_key).present? &&
      details.fetch(:idempotency_key).all? { |detail| detail[:error] == :taken }
  end

  def duplicate_idempotency_domain_error?(error)
    error.code == 'DUPLICATE_IDEMPOTENCY_KEY' &&
      error.details.to_h.with_indifferent_access == { 'idempotency_key' => ['has already been taken'] }
  end

  def validate_context!
    raise ArgumentError, 'CRM tasks feature is disabled' unless account.feature_enabled?('crm_tasks')
    raise ArgumentError, 'Current conversation is required' unless conversation&.account_id == account.id
    raise ArgumentError, 'Current contact is required' if contact.blank?
    raise ArgumentError, 'Current communication thread is required' if communication_thread.blank?
    return if communication_thread.contact_id == contact.id

    raise ArgumentError, 'Current conversation contact and communication thread do not match'
  end

  def validate_idempotency_key!(action, value)
    return unless MUTATING_ACTIONS.include?(action)
    return if value.is_a?(String) && value.present?

    raise ArgumentError, 'idempotency_key is required for mutating actions'
  end

  def contact
    @contact ||= conversation&.contact
  end

  def communication_thread
    @communication_thread ||= conversation&.communication_thread
  end

  def compact_hash(attributes)
    attributes.compact
  end
end
