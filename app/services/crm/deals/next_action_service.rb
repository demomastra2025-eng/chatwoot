class Crm::Deals::NextActionService
  OPEN_TASK_CATEGORIES = %w[open in_progress].freeze

  def initialize(deal:, now: Time.zone.now)
    @deal = deal
    @now = now
    @timezone = Time.find_zone(deal.account.workspace_working_hours_timezone) || Time.zone
  end

  def perform
    return no_action('closed') if deal.closed?
    return waiting_action if deal.waiting?

    task = next_open_task
    return no_action('no_open_task') if task.blank?

    task_action(task)
  end

  private

  attr_reader :deal, :now, :timezone

  def waiting_action
    {
      kind: deal.waiting_expired?(at: now) ? 'waiting_expired' : 'waiting',
      waiting_until: deal.waiting_until.iso8601,
      waiting_reason: deal.waiting_reason,
      waiting_started_at: deal.waiting_started_at&.iso8601,
      waiting_set_by_id: deal.waiting_set_by_id
    }
  end

  def no_action(reason)
    { kind: 'none', reason: reason }
  end

  def task_action(task)
    {
      kind: 'task',
      state: task_time_state(task),
      due_at: task.due_at&.iso8601,
      due_on: task.due_on&.iso8601,
      task: Crm::PayloadBuilder.task(task)
    }
  end

  def next_open_task
    open_tasks.min_by { |task| task_sort_key(task) }
  end

  def open_tasks
    scope = deal.tasks
    records = scope.loaded? ? scope.target : scope.includes(:status).to_a
    records.select do |task|
      task.archived_at.nil? && OPEN_TASK_CATEGORIES.include?(task.status.category)
    end
  end

  def task_sort_key(task)
    [task_time_bucket(task), task.effective_due_at || Time.utc(9999, 12, 31), task.id]
  end

  def task_time_bucket(task)
    case task_time_state(task)
    when 'overdue' then 0
    when 'today' then 1
    when 'future' then 2
    else 3
    end
  end

  def task_time_state(task)
    return date_state(task.due_on) if task.all_day? && task.due_on.present?
    return 'unscheduled' if task.due_at.blank?
    return 'overdue' if task.due_at < now
    return 'today' if task.due_at.in_time_zone(timezone).to_date == local_today

    'future'
  end

  def date_state(date)
    return 'overdue' if date < local_today
    return 'today' if date == local_today

    'future'
  end

  def local_today
    @local_today ||= now.in_time_zone(timezone).to_date
  end
end
