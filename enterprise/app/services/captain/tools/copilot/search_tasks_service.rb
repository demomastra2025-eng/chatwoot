class Captain::Tools::Copilot::SearchTasksService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_tasks'
  end

  description 'Search CRM tasks by title, status, assignee, deal, or priority'
  param :query, type: :string, desc: 'Task title or external reference query', required: false
  param :status_name, type: :string, desc: 'Task status name', required: false
  param :assignee_id, type: :integer, desc: 'Positive assignee user ID. Omit when unknown.', required: false
  param :deal_id, type: :integer, desc: 'Positive deal ID. Omit when unknown.', required: false
  param :priority, type: :string, desc: 'Task priority: low, medium, high, or urgent', required: false
  param :archived, type: :boolean, desc: 'Whether to search archived tasks', required: false
  param :limit, type: :number, desc: 'Maximum number of tasks to return', required: false

  def execute(query: nil, status_name: nil, assignee_id: nil, deal_id: nil, priority: nil, archived: nil, limit: nil)
    assignee_id = optional_positive_id(assignee_id)
    deal_id = optional_positive_id(deal_id)

    tasks = account.crm_tasks.includes(:status, :assignee, :team, :deal)
    tasks = cast_boolean(archived) ? tasks.archived : tasks.kept
    tasks = tasks.where(assignee_id: assignee_id) if assignee_id.present?
    tasks = tasks.where(deal_id: deal_id) if deal_id.present?
    tasks = tasks.where(priority: priority) if priority.present?
    tasks = tasks.joins(:status).where('LOWER(crm_task_statuses.name) = ?', status_name.to_s.downcase) if status_name.present?
    tasks = tasks.where('crm_tasks.title ILIKE :query OR crm_tasks.external_ref ILIKE :query', query: "%#{query.strip}%") if query.present?

    total_count = tasks.count
    records = tasks.ordered.limit(parse_limit(limit)).map { |task| Crm::PayloadBuilder.task(task) }

    formatted_payload(
      filters: {
        query: query,
        status_name: status_name,
        assignee_id: assignee_id,
        deal_id: deal_id,
        priority: priority,
        archived: cast_boolean(archived)
      }.compact,
      total_count: total_count,
      tasks: records
    )
  end

  def active?
    feature_enabled?('crm_tasks') && (user_has_permission('crm_task_view') || user_has_permission('crm_task_manage'))
  end
end
