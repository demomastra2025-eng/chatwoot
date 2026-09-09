class Crm::Tasks::CatalogSnapshot
  def initialize(account:)
    @task_types = account.crm_task_types.includes(:outcomes).ordered.to_a
    @task_types_by_code = @task_types.index_by(&:code)
  end

  def task_type_for(task)
    task.task_type || task_types_by_code[task.activity_type] || default_task_type
  end

  def task_outcome_for(task, task_type: task_type_for(task))
    return task.task_outcome if task.task_outcome.present?
    return if task_type.blank? || task.outcome.blank?

    task_type.outcomes.find { |outcome| outcome.code == task.outcome }
  end

  private

  attr_reader :task_types, :task_types_by_code

  def default_task_type
    @default_task_type ||= task_types.find { |task_type| task_type.active? && task_type.default? } ||
                           task_types.find(&:active?)
  end
end
